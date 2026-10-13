import XCTest
@testable import SteamLauncherKit

final class LocalReadinessTests: XCTestCase {
    private var root: URL!
    private var launcher: SteamLauncher!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("local-readiness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        launcher = SteamLauncher(profile: .halfLifeAlyx, installRoot: root)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func completedInstall(manifests: [String: UInt64]? = nil) throws {
        let state = SteamLauncher.InstalledState(buildID: 123,
            manifests: manifests ?? ["546561": 1, "546564": 2], date: Date())
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent(".launcher-install.json"))
        for path in launcher.profile.requiredFiles {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("essential asset".utf8).write(to: file)
        }
    }

    func testCompletedOlderBuildIsReadyWithoutSteamOrMatchingTheLatestPinnedManifest() throws {
        try completedInstall()
        XCTAssertEqual(launcher.playableInstallation?.buildID, 123)
        XCTAssertNil(launcher.logon, "Readiness must not require a Steam connection")
    }

    func testFirstInstallAndMalformedReceiptAreNotReady() throws {
        XCTAssertNil(launcher.playableInstallation)
        try Data("incomplete receipt".utf8).write(to: root.appendingPathComponent(".launcher-install.json"))
        XCTAssertNil(launcher.playableInstallation)
    }

    func testMissingDepotOrEssentialAssetIsNotReady() throws {
        try completedInstall(manifests: ["546561": 1])
        XCTAssertNil(launcher.playableInstallation)
        try completedInstall()
        let file = root.appendingPathComponent(launcher.profile.requiredFiles[0])
        try FileManager.default.removeItem(at: file)
        XCTAssertNil(launcher.playableInstallation)
        try Data().write(to: file)
        XCTAssertNil(launcher.playableInstallation, "Empty placeholders are not required game assets")
    }

    func testPartialDownloadAndPausedUpdateCannotReuseAnOldCompleteReceipt() throws {
        try completedInstall()
        for marker in [".launcher-downloading", ".launcher-installing"] {
            let file = root.appendingPathComponent(marker)
            try Data().write(to: file)
            XCTAssertNil(launcher.playableInstallation, "\(marker) must prevent optimistic Play")
            try FileManager.default.removeItem(at: file)
            XCTAssertNotNil(launcher.playableInstallation)
        }
    }

    func testCanceledUpdateLeavesPersistentMarkerAndCompletionClearsIt() async throws {
        try completedInstall()
        let plan = SteamLauncher.InstallPlan(buildID: 456, depots: [], servers: [])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await launcher.install(plan, progress: { _ in })
        }
        do {
            try await task.value
            XCTFail("Canceled installation should not finish")
        } catch is CancellationError {}
        XCTAssertNil(launcher.playableInstallation)
        XCTAssertEqual(launcher.installed?.buildID, 123, "The old receipt remains, but is not playable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".launcher-installing").path))
        try await launcher.install(plan, progress: { _ in })
        XCTAssertEqual(launcher.installed?.buildID, 456)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".launcher-installing").path))
    }
}
