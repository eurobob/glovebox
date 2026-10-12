import XCTest
@testable import SteamLauncherKit

final class InstallSpaceTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("install-space-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// FileHandle.truncate creates a sparse logical size; it does not write the
    /// synthetic multi-gigabyte content represented by these manifests.
    private func sparseFile(_ url: URL, size: UInt64) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: size)
    }

    private func chunk(_ id: UInt8, size: UInt32, compressed: UInt32? = nil,
                       offset: UInt64 = 0) -> DepotManifest.Chunk {
        .init(sha: Data(repeating: id, count: 20), checksum: 0, offset: offset,
              size: size, compressedSize: compressed ?? size)
    }

    private func file(_ name: String, chunks: [DepotManifest.Chunk]) -> DepotManifest.File {
        .init(name: name, size: chunks.reduce(0) { $0 + UInt64($1.size) },
              flags: 0, sha: Data(), chunks: chunks)
    }

    private func downloader(_ manifest: DepotManifest, root: URL) -> DepotDownloader {
        DepotDownloader(cdn: CDNClient(servers: []), depotID: manifest.depotID,
                        key: Data(), manifest: manifest, root: root)
    }

    private func journal(_ manifest: DepotManifest, entries: [String], root: URL) throws {
        try Data((entries.joined(separator: "\n") + "\n").utf8).write(to: root.appendingPathComponent(
            ".steam-journal-\(manifest.depotID)-\(manifest.manifestID)"))
    }

    private func launcher(root: URL) -> SteamLauncher {
        let unusedURL = URL(string: "https://example.invalid/")!
        let profile = GameProfile(appID: 1, title: "Install-space test", depots: [],
                                  localPath: { $0 }, policy: { _ in .download }, cloudRoots: [:],
                                  storeURL: unusedURL, heroImageURL: unusedURL, logoURL: unusedURL)
        return SteamLauncher(profile: profile, installRoot: root)
    }

    private func plan(_ manifests: [DepotManifest], key: Data = Data()) -> SteamLauncher.InstallPlan {
        .init(buildID: 44, depots: manifests.map {
            .init(depotID: $0.depotID, manifest: $0, key: key, bytes: $0.totalSize)
        }, servers: [])
    }

    func testFreeSpaceFindsExistingAncestorWithoutCreatingInstallFolders() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Skip only when this test volume itself does not expose capacity; a
        // missing nested path must not turn a supported query into nil.
        #if os(Linux)
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        try XCTSkipIf(attributes[.systemFreeSize] == nil, "The test volume does not report free capacity")
        #else
        let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        try XCTSkipIf(capacity.volumeAvailableCapacityForImportantUsage == nil,
                      "The test volume does not report important-usage capacity")
        #endif
        let futureRoot = root.appendingPathComponent("new-game/assets/install", isDirectory: true)
        XCTAssertNotNil(launcher(root: futureRoot).freeSpace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: futureRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new-game").path),
                       "Checking capacity must not create any install directory")
    }

    func test67GBPlanCredits7GBJournalButNotSparsePreallocation() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gb: UInt64 = 1_000_000_000
        let chunks = (0..<67).map { chunk(UInt8($0), size: UInt32(gb), offset: UInt64($0) * gb) }
        let manifest = DepotManifest(depotID: 7, manifestID: 99,
                                     files: [file("large.vpk", chunks: chunks)])
        let game = launcher(root: root)
        let install = plan([manifest])
        try sparseFile(root.appendingPathComponent("large.vpk"), size: 67 * gb)
        let allocated = try root.appendingPathComponent("large.vpk")
            .resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize ?? 0
        XCTAssertLessThan(allocated, 1_048_576, "The 67 GB fixture must remain sparse")
        XCTAssertEqual(game.additionalBytesRequired(install), 67 * gb,
                       "Preallocation alone is not evidence of downloaded chunks")

        try journal(manifest, entries: chunks.prefix(7).map { "large.vpk\t\($0.offset)" }, root: root)
        XCTAssertEqual(downloader(manifest, root: root).installFootprint(staged: nil).completedBytes, 7 * gb)
        XCTAssertEqual(game.additionalBytesRequired(install), 60 * gb)
    }

    func testJournalRequiresMatchingManifestAndCompleteDestinationRanges() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let chunks = [chunk(1, size: 200), chunk(2, size: 200, offset: 200)]
        let manifest = DepotManifest(depotID: 7, manifestID: 99, files: [file("data.bin", chunks: chunks)])
        let wrongManifest = DepotManifest(depotID: 7, manifestID: 98, files: manifest.files)
        let dl = downloader(manifest, root: root)
        let output = root.appendingPathComponent("data.bin")
        let entries = ["data.bin\t0", "data.bin\t200"]
        try sparseFile(output, size: 400)
        try journal(wrongManifest, entries: entries, root: root)
        XCTAssertEqual(dl.installFootprint(staged: nil).completedBytes, 0,
                       "A different manifest's journal grants no resume credit")

        try journal(manifest, entries: entries, root: root)
        try FileManager.default.removeItem(at: output)
        XCTAssertEqual(dl.installFootprint(staged: nil).growthBytes, 400,
                       "A journal cannot stand in for a missing output")
        try sparseFile(output, size: 199)
        XCTAssertEqual(dl.installFootprint(staged: nil).completedBytes, 0,
                       "Even the first chunk is incomplete after truncation")
        try sparseFile(output, size: 250)
        let partial = dl.installFootprint(staged: nil)
        XCTAssertEqual(partial.completedBytes, 200, "Only the fully present first range counts")
        XCTAssertEqual(partial.growthBytes, 200)
    }

    func testStagedCreditCapsLogicalWirePlainAndAllocatedBytes() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = StagedChunks(installRoot: root)
        try FileManager.default.createDirectory(at: staged.folder, withIntermediateDirectories: true)
        let chunks = [
            chunk(1, size: 200, compressed: 80),       // wire-size cap
            chunk(2, size: 200, compressed: 500),      // plain-size cap
            chunk(3, size: 200, compressed: 100),      // logical-size cap
            chunk(4, size: 2_097_152, compressed: 1_048_576), // sparse allocation cap
        ]
        let manifest = DepotManifest(depotID: 7, manifestID: 99,
                                     files: chunks.enumerated().map { file("file\($0.offset)", chunks: [$0.element]) })
        for (index, bytes) in [100, 300, 40].enumerated() {
            try Data(repeating: 0xAA, count: bytes).write(to: staged.url(StagedChunks.name(depotID: 7, chunks[index])))
        }
        let sparseURL = staged.url(StagedChunks.name(depotID: 7, chunks[3]))
        try sparseFile(sparseURL, size: 1_048_576)
        let sparseAllocated = UInt64(max(0, try sparseURL.resourceValues(forKeys: [.fileAllocatedSizeKey])
            .fileAllocatedSize ?? 0))
        XCTAssertLessThan(sparseAllocated, 1_048_576, "Logical staged bytes must not masquerade as allocated bytes")
        let footprint = downloader(manifest, root: root).installFootprint(staged: staged, unpackers: 4)
        XCTAssertEqual(footprint.completedBytes, 0)
        XCTAssertEqual(footprint.growthBytes, manifest.totalSize - 80 - 200 - 40 - sparseAllocated)
        XCTAssertEqual(footprint.unpackPeakBytes, manifest.totalSize,
                       "All four staged inputs remain allocated during a four-worker decode peak")
    }

    func testUnpackPeakReservesLargestConcurrentStagedInputs() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = StagedChunks(installRoot: root)
        try FileManager.default.createDirectory(at: staged.folder, withIntermediateDirectories: true)
        let chunks = [chunk(1, size: 10_000, compressed: 100),
                      chunk(2, size: 10_000, compressed: 200),
                      chunk(3, size: 10_000, compressed: 300)]
        let manifest = DepotManifest(depotID: 7, manifestID: 99,
                                     files: chunks.enumerated().map { file("file\($0.offset)", chunks: [$0.element]) })
        for c in chunks {
            try Data(repeating: 0xAA, count: Int(c.compressedSize))
                .write(to: staged.url(StagedChunks.name(depotID: 7, c)))
        }
        let dl = downloader(manifest, root: root)
        XCTAssertEqual(dl.installFootprint(staged: staged, unpackers: 1).growthBytes, 29_400)
        XCTAssertEqual(dl.installFootprint(staged: staged, unpackers: 1).unpackPeakBytes, 29_700)
        XCTAssertEqual(dl.installFootprint(staged: staged, unpackers: 2).unpackPeakBytes, 29_900)
        XCTAssertEqual(dl.installFootprint(staged: staged, unpackers: 3).unpackPeakBytes, 30_000)
    }

    func testLastDepotUnpackPeakCannotUseItsOwnUnreclaimedInputSpace() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stagedChunk = chunk(1, size: 10_000, compressed: 9_000)
        let cached = DepotManifest(depotID: 7, manifestID: 99, files: [file("cached", chunks: [stagedChunk])])
        let network = DepotManifest(depotID: 8, manifestID: 100,
                                    files: [file("network", chunks: [chunk(2, size: 20_000)])])
        let game = launcher(root: root)
        try FileManager.default.createDirectory(at: game.staged.folder, withIntermediateDirectories: true)
        try Data(repeating: 0xAA, count: 9_000).write(to: game.staged.url(StagedChunks.name(depotID: 7, stagedChunk)))

        XCTAssertEqual(game.additionalBytesRequired(plan([cached, network])), 21_000,
                       "Unpacking first reclaims the cached input before later foreground writes")
        XCTAssertEqual(game.additionalBytesRequired(plan([network, cached])), 30_000,
                       "Unpacking last must fit the full output before removing its cached input")
    }

    func testInstallProgressStartsWithJournaledBytesFromLaterDepots() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let vzip = Data(base64Encoded: "Vlph3gRyjV0AAAEAACQYSYZ5PgrXgTq7Cp1HdUdheYtk5LdaUbidBI8D855j8unFiqCWeG+FAfD3rkXOjbw6W8f//wNiAADeBHKNyAUAAHp2")!
        let plain = Data(String(repeating: "Half-Life: Alyx on Apple Vision Pro. ", count: 40).utf8)
        let key = Data((0..<32).map { UInt8(255 - $0) })
        let raw = try Codec.steamEncrypt(vzip, key: key)
        let firstChunk = DepotManifest.Chunk(sha: Codec.sha1(plain), checksum: Codec.adler32Seed0(plain),
                                             offset: 0, size: UInt32(plain.count), compressedSize: UInt32(raw.count))
        let first = DepotManifest(depotID: 7, manifestID: 99, files: [file("first", chunks: [firstChunk])])
        let laterData = Data(repeating: 0xBE, count: 500)
        let later = DepotManifest(depotID: 8, manifestID: 100, files: [file("later", chunks: [chunk(2, size: 500)])])
        try laterData.write(to: root.appendingPathComponent("later"))
        try journal(later, entries: ["later\t0"], root: root)
        let game = launcher(root: root)
        try FileManager.default.createDirectory(at: game.staged.folder, withIntermediateDirectories: true)
        try raw.write(to: game.staged.url(StagedChunks.name(depotID: 7, firstChunk)))
        let snapshots = ProgressSnapshots()
        let install = plan([first, later], key: key)
        // No CDN servers: every byte must come from the staged input or journal.
        try await game.install(install) { snapshots.append($0) }
        let progress = snapshots.values
        XCTAssertEqual(progress.first?.doneBytes, 500, "Later completed depots count from the first update")
        XCTAssertTrue(progress.allSatisfy { $0.totalBytes == install.totalBytes && $0.doneBytes <= install.totalBytes })
        XCTAssertTrue(zip(progress, progress.dropFirst()).allSatisfy { pair in
            pair.0.doneBytes <= pair.1.doneBytes
        })
        XCTAssertEqual(progress.last?.doneBytes, install.totalBytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("first")), plain)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("later")), laterData)
        XCTAssertEqual(game.installed?.buildID, 44)
        XCTAssertEqual(game.additionalBytesRequired(install), 0)
    }
}

private final class ProgressSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DownloadProgress] = []
    func append(_ progress: DownloadProgress) {
        lock.lock(); defer { lock.unlock() }
        storage.append(progress)
    }
    var values: [DownloadProgress] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
