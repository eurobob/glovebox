import Foundation
import SwiftUI
import UIKit
import SteamLauncherKit

/// UI state for the launcher. Every Steam call goes through `SteamLauncher`; this class only
/// turns results into screens.
@MainActor
final class LauncherModel: ObservableObject {
    enum Phase: Equatable {
        case starting
        case signIn
        case checkingOwnership
        case notOwned
        case library
    }

    enum SignInStep: Equatable {
        case idle
        case working
        case approveInApp(canEnterCode: Bool)
        case enterCode(email: String?)
    }

    enum InstallState: Equatable {
        case unknown
        case preparing
        case notInstalled
        case downloading(DownloadProgress)
        case paused(DownloadProgress)
        case installed(updateAvailable: Bool)
        case failed(String)
    }

    @Published var phase: Phase = .starting
    @Published var signInStep: SignInStep = .idle
    @Published var signInError: String?
    @Published var accountName = ""
    @Published var install: InstallState = .unknown
    @Published var downloadBytes: UInt64 = 0
    @Published var freeSpace: UInt64?
    /// Additional space still needed, including temporary-download headroom.
    @Published var requiredInstallSpace: UInt64?
    @Published var checkingInstallSpace = false
    @Published var buildID: UInt64 = 0
    /// True between Play and the game starting, while Play waits for the latest saves (`latestSaves`).
    @Published var launching = false
    @Published var requestingTrackingPermission = false
    @Published var inputMode = LauncherInputMode.saved {
        didSet {
            UserDefaults.standard.set(inputMode.rawValue, forKey: LauncherInputMode.defaultsKey)
            refreshControllerAccess()
        }
    }
    /// Steam Cloud, as the page shows it: nil until the first sync starts.
    @Published var saves: Saves?
    /// Permissions for hands and Sense, plus connected controllers (Controllers.swift).
    @Published var controllers = ControllerState()
    /// Set by the game app between Play and the game's first frame, while the game gets ready (the
    /// first launch prepares its graphics). The page shows it in place of Play; nil hides it. Set it
    /// inside the closure passed to `play`, so the page goes straight from syncing saves to this.
    @Published var preparing: Preparing?
    /// May the headset send stutter reports (StutterSharing.swift): nil until someone answers, on
    /// the Mac or here.
    @Published var shareStutters: Bool? = StutterSharing.choice
    /// A newer Glovebox release than this app was built from (GloveboxUpdate.swift), or nil.
    @Published var gloveboxUpdate: String? = GloveboxUpdateCheck.known

    enum Saves: Equatable {
        case syncing(CloudSync.Progress)
        case synced
        case failed
    }

    struct Preparing: Equatable {
        /// 0...1.
        var fraction: Double
        var secondsLeft: Double?
        /// Says so on the page, so nobody expects the wait every time.
        var firstTimeOnly = true
        var title = "Preparing graphics"
    }

    let profile: GameProfile
    let launcher: SteamLauncher
    private var plan: SteamLauncher.InstallPlan?
    private var passwordSession: SteamAuthSession?
    private var signInTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var spaceRefreshTask: Task<Void, Never>?
    private var backgroundHandoffTask: Task<Void, Never>?
    private var saveSync: Task<Void, Never>?
    /// The running sync has put every save from the cloud in place; only its uploads are left, so the game may start.
    private var savesInPlace = false
    /// When the running sync last moved on (a stage or a file).
    private var savesMovedAt = Date()
    private var playTask: Task<Void, Never>?
    /// Whether the app is in front. Downloads move to the system's background downloader when it isn't.
    private var isActive = false
    /// A download that should pick up again as soon as the app is back in front.
    private var resumeWhenActive = false
    private var checkingForGloveboxUpdate = false

    /// The system's background downloader for game chunks. One per app; the app delegate needs it
    /// before any window (and model) exists, when the system wakes the app for finished downloads.
    /// Named after the app, so each player's own build (its bundle id carries their team) has its own.
    nonisolated static let backgroundFetcher = BackgroundChunkFetcher(
        identifier: (Bundle.main.bundleIdentifier ?? "io.github.glovebox-vr.launcher") + ".chunks",
        installRoot: defaultInstallRoot)

    init(profile: GameProfile = .halfLifeAlyx, installRoot: URL = LauncherModel.defaultInstallRoot) {
        self.profile = profile
        self.launcher = SteamLauncher(profile: profile, installRoot: installRoot)
        UserDefaults.standard.set(inputMode.rawValue, forKey: LauncherInputMode.defaultsKey)
        if let demo = DemoState.current {
            demo.apply(to: self)
        } else {
            watchControllers()
            Task { await start() }
        }
    }

    /// The Klepton app reads game data from Documents/alyx/assets.
    nonisolated static var defaultInstallRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("alyx/assets", isDirectory: true)
    }

    /// What of Documents stays in the device's iCloud backup: the saves (in Steam Cloud too) and the
    /// sync's records of them. The rest, the game (about 60 GB) and its shader cache, downloads or
    /// builds again; a tester's backup was 68.7 GB with it.
    nonisolated static let backupKeeps = ["alyx/assets/hlvr/save", "alyx/assets/.launcher-cloud.json", "alyx/assets/.cloud-backups"]

    /// Marks everything else in Documents excluded from backup: on every start (the game and its
    /// shader cache add files beside the saves), after each download, and when a download goes to
    /// the system (the headset backs up overnight, maybe halfway through a first download).
    @discardableResult
    nonisolated static func keepOutOfBackup() -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            _ = BackupExclusion.apply(under: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
                                      keeping: LauncherModel.backupKeeps)
        }
    }

    // MARK: Start

    func start() async {
        Self.keepOutOfBackup()
        if let creds = Keychain.load() {
            accountName = creds.accountName
            await finishSignIn(creds)
        } else {
            phase = .signIn
        }
    }

    // MARK: Sign-in

    func signIn(account: String, password: String) {
        signInError = nil
        signInStep = .working
        signInTask?.cancel()
        signInTask = Task {
            do {
                let session = try await launcher.beginPasswordSignIn(account: account, password: password,
                                                                     guardData: Keychain.guardData(for: account))
                passwordSession = session
                accountName = account
                switch session.prompt {
                case .approveInApp(let canEnterCode): signInStep = .approveInApp(canEnterCode: canEnterCode)
                case .deviceCode: signInStep = .enterCode(email: nil)
                case .emailCode(let hint): signInStep = .enterCode(email: hint)
                case .qr: break
                }
                let creds = try await session.waitForApproval()
                await finishSignIn(creds)
            } catch {
                // Cancelled from the Steam Guard screen: back to the form without an error.
                if Task.isCancelled { return }
                signInStep = .idle
                signInError = Self.friendly(error)
            }
        }
    }

    func submitCode(_ code: String) {
        guard let s = passwordSession else { return }
        Task {
            do { try await s.submit(code: code) } catch { signInError = Self.friendly(error) }
        }
    }

    func useCodeInstead() { signInStep = .enterCode(email: nil) }

    func cancelSignIn() {
        signInTask?.cancel()
        passwordSession = nil
        signInStep = .idle
    }

    private func finishSignIn(_ creds: SteamCredentials) async {
        var creds = creds
        if creds.accountName.isEmpty { creds.accountName = accountName }
        Keychain.save(creds)
        accountName = creds.accountName
        signInStep = .idle
        phase = .checkingOwnership
        do {
            try await launcher.logOn(creds)
            let own = try await launcher.checkOwnership()
            guard own.owned else { phase = .notOwned; return }
            phase = .library
            // Saves from the last session go up, and saves from other PCs come down, in the background, while the
            // game's build is checked: by the time the player looks for Play they're usually in.
            syncSavesInBackground()
            await refreshInstall()
        } catch SteamError.result(let r, _) where r == .invalidPassword || r == .accessDenied || r == .expired {
            Keychain.clear()
            phase = .signIn
            signInError = "Sign in again"
        } catch {
            phase = .signIn
            signInError = Self.friendly(error)
        }
    }

    func signOut() {
        installTask?.cancel()
        spaceRefreshTask?.cancel()
        let handoff = backgroundHandoffTask
        handoff?.cancel()
        wasDownloading = false
        resumeWhenActive = false
        Task {
            await handoff?.value
            await Self.backgroundFetcher.stop()
        }
        Task { await launcher.signOut() }
        Keychain.clear()
        accountName = ""
        install = .unknown
        phase = .signIn
    }

    // MARK: Install

    func refreshInstall() async {
        spaceRefreshTask?.cancel()
        install = .preparing
        freeSpace = launcher.freeSpace
        do {
            let p = try await launcher.plan()
            plan = p
            buildID = p.buildID
            downloadBytes = p.totalBytes
            await refreshInstallSpace(for: p)
            install = launcher.installed == nil ? .notInstalled : .installed(updateAvailable: launcher.needsUpdate(p))
            // A download that was running when the app last went away picks up on its own.
            if wasDownloading, case .installed(updateAvailable: false) = install {
                wasDownloading = false
            } else if wasDownloading {
                if isActive { startInstall() } else { resumeWhenActive = true }
            }
        } catch {
            install = .failed(Self.friendly(error))
        }
    }

    var hasRoomForInstall: Bool {
        guard let freeSpace, let requiredInstallSpace else { return true }
        return freeSpace >= requiredInstallSpace
    }

    private func refreshInstallSpace(for plan: SteamLauncher.InstallPlan) async {
        let launcher = self.launcher
        let remaining = await Task.detached(priority: .utility) {
            launcher.additionalBytesRequired(plan)
        }.value
        guard !Task.isCancelled else { return }
        requiredInstallSpace = remaining + 2_000_000_000
        // Read after inspecting existing chunks: background transfers may have progressed.
        freeSpace = launcher.freeSpace
    }

    func setShareStutters(_ on: Bool) {
        StutterSharing.set(on)
        shareStutters = on
    }

    func startInstall() {
        guard !checkingInstallSpace else { return }
        guard let plan else {
            // A failed first manifest request leaves no plan. Try Again must plan again.
            guard install != .preparing else { return }
            install = .preparing
            Task { await refreshInstall() }
            return
        }
        spaceRefreshTask?.cancel()
        let previous = installTask
        previous?.cancel()
        let handoff = backgroundHandoffTask
        handoff?.cancel()
        resumeWhenActive = false
        checkingInstallSpace = true
        installTask = Task {
            await previous?.value
            await handoff?.value
            // Stop adding background batches before measuring the remaining footprint.
            // This cancels requests and removes their queue, but preserves staged chunks.
            await Self.backgroundFetcher.stop()
            await refreshInstallSpace(for: plan)
            checkingInstallSpace = false
            guard !Task.isCancelled else { return }
            guard hasRoomForInstall else {
                if case .downloading(let progress) = install { install = .paused(progress) }
                return
            }
            guard isActive else { resumeWhenActive = true; return }
            resumeWhenActive = false
            wasDownloading = true
            install = .downloading(DownloadProgress(totalBytes: plan.totalBytes))
            do {
                try await runInstall(plan)
                Self.keepOutOfBackup()
                wasDownloading = false
                install = .installed(updateAvailable: false)
                syncSavesInBackground()
            } catch is CancellationError {
            } catch {
                // Cancelled on purpose: paused, signed out, or handed to the background downloader.
                if Task.isCancelled { return }
                if case .paused = install { return }
                install = .failed(Self.friendly(error))
            }
        }
    }

    /// In front, unpack staged chunks and finish directly. Background batches are stopped before
    /// the space check; a new batch is handed to the system only when the app goes to the background.
    private func runInstall(_ plan: SteamLauncher.InstallPlan) async throws {
        let report: @Sendable (DownloadProgress) -> Void = { p in
            Task { @MainActor [weak self] in
                guard let self, case .downloading = self.install else { return }
                self.install = .downloading(p)
            }
        }
        try await launcher.install(plan, progress: report)
    }

    func pauseInstall() {
        if case .downloading(let p) = install { install = .paused(p) }
        installTask?.cancel()
        let handoff = backgroundHandoffTask
        handoff?.cancel()
        wasDownloading = false
        resumeWhenActive = false
        Task {
            await handoff?.value
            await Self.backgroundFetcher.stop()
        }
    }

    // MARK: In front, or not

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isActive = true
            spaceRefreshTask?.cancel()
            if resumeWhenActive {
                startInstall()
            } else if let plan {
                spaceRefreshTask = Task { await refreshInstallSpace(for: plan) }
            } else {
                freeSpace = launcher.freeSpace
            }
            // Also at launch: both apps pass the first phase too.
            if DemoState.current == nil { checkForGloveboxUpdate() }
            // Back from Settings, tracking may have just been turned on.
            refreshControllerAccess()
        case .background:
            isActive = false
            if checkingInstallSpace {
                resumeWhenActive = true
            } else {
                handDownloadToSystem()
            }
        default:
            break
        }
    }

    /// Asks whether a newer Glovebox is out (GloveboxUpdateCheck), when the last answer is a few hours old.
    func checkForGloveboxUpdate() {
        guard !checkingForGloveboxUpdate else { return }
        checkingForGloveboxUpdate = true
        Task {
            let newer = await GloveboxUpdateCheck.refresh()
            checkingForGloveboxUpdate = false
            withAnimation(.spring(duration: 0.5)) { gloveboxUpdate = newer }
        }
    }

    /// Every window is closed or out of sight, so the app is about to be suspended. Stops the
    /// in-app download cleanly and leaves the rest to the system's background downloader; the
    /// app picks it up again when it comes back.
    private func handDownloadToSystem() {
        guard case .downloading = install, let plan else { return }
        resumeWhenActive = true
        let running = installTask
        running?.cancel()
        // A few seconds of grace to finish the hand-off before the app is suspended.
        let assertion = BackgroundAssertion()
        assertion.id = UIApplication.shared.beginBackgroundTask(withName: "Hand download to the system") {
            MainActor.assumeIsolated { assertion.end() }
        }
        let launcher = self.launcher
        backgroundHandoffTask = Task {
            defer { assertion.end() }
            await running?.value  // the journal is flushed when the in-app download stops
            guard !Task.isCancelled, !isActive, resumeWhenActive else { return }
            let remaining = await Task.detached { launcher.remainingChunks(plan) }.value
            guard !Task.isCancelled, !isActive, resumeWhenActive else { return }
            await Self.backgroundFetcher.plan(remaining, servers: CDNClient(servers: plan.servers).baseURLs)
            await Self.keepOutOfBackup().value  // the game so far and the system's chunk folder
        }
    }

    /// Set while a download is unfinished, so it resumes by itself after the app is relaunched.
    private var wasDownloading: Bool {
        get { FileManager.default.fileExists(atPath: downloadingMarker.path) }
        set {
            if newValue {
                try? FileManager.default.createDirectory(at: launcher.installRoot, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: downloadingMarker.path, contents: Data())
            } else {
                try? FileManager.default.removeItem(at: downloadingMarker)
            }
        }
    }

    private var downloadingMarker: URL { launcher.installRoot.appendingPathComponent(".launcher-downloading") }

    // MARK: Saves (Steam Cloud)

    /// The one switch for uploads. Off is download-only: saves come down from Steam, nothing goes up,
    /// and every sync logs what would have gone up. On since a real-account test (2026-10-09): a new
    /// headset save went up and nothing else in the cloud changed.
    static var cloudUploads = true

    /// Syncs saves the way Steam does: nobody has to think about it. A failed sync (e.g. offline) is
    /// retried at Play and at the next launch; nothing is lost because local saves are only replaced after a backup.
    func syncSavesInBackground() {
        guard saveSync == nil else { return }
        savesInPlace = false
        savesMovedAt = Date()
        saves = .syncing(CloudSync.Progress(stage: .checking))
        saveSync = Task {
            let ok = await syncSaves()
            savesInPlace = false
            withAnimation(.spring(duration: 0.5)) { saves = ok ? .synced : .failed }
            saveSync = nil
        }
    }

    private func syncSaves() async -> Bool {
        let t0 = Date()
        let progress: @Sendable (CloudSync.Progress) async -> Void = { [weak self] p in
            await MainActor.run { self?.savesProgressed(p, since: t0) }
        }
        do {
            let r = try await launcher.syncSaves(uploads: Self.cloudUploads, progress: progress)
            NSLog("%@", "[launcher] cloud sync (uploads \(Self.cloudUploads ? "on" : "off")) in \(Self.seconds(since: t0)): "
                  + "downloaded \(r.downloaded.count), uploaded \(r.uploaded.count), unchanged \(r.unchanged), "
                  + "backed up \(r.backedUp), relocated \(r.relocated), would upload \(r.wouldUpload)")
            return true
        } catch {
            NSLog("%@", "[launcher] cloud sync failed after \(Self.seconds(since: t0)): \(error)")
            return false
        }
    }

    private func savesProgressed(_ p: CloudSync.Progress, since t0: Date) {
        guard case .syncing(let was) = saves else { return }
        if p.stage != was.stage {
            NSLog("%@", "[launcher] cloud sync: \(p.stage) \(p.total) files at \(Self.seconds(since: t0))")
        }
        if p.savesInPlace { savesInPlace = true }
        savesMovedAt = Date()
        saves = .syncing(p)
    }

    /// Play waits for saves as long as they keep coming. When nothing has moved for this long (Steam stopped
    /// answering), the game starts with the saves it has, and the sync finishes at the next launch.
    static let playStall: TimeInterval = 10
    /// The most Play waits for the quick look at the cloud after a sync (it usually takes well under a second).
    static let quickCheckWait: TimeInterval = 4

    /// Play: the selected tracking permission first (the system asks here, not as the game starts), then the latest
    /// saves, then the game.
    func play(_ start: @escaping () -> Void) {
        guard playTask == nil, !launching, preparing == nil, controllerIssue == nil else { return }
        let selectedMode = inputMode
        requestingTrackingPermission = true
        playTask = Task {
            defer {
                requestingTrackingPermission = false
                playTask = nil
            }
            guard await allowControllerTracking(), inputMode == selectedMode, controllerIssue == nil else { return }
            requestingTrackingPermission = false
            launching = true
            let t0 = Date()
            await latestSaves()
            NSLog("%@", "[launcher] Play: saves ready in \(Self.seconds(since: t0))")
            launching = false
            start()
        }
    }

    /// Every save from the cloud in place before the game starts, usually with no wait: the sync that started with
    /// the launcher brought them, and one quick look at the cloud catches a save made elsewhere since. A full sync
    /// runs only when that look finds one, or when the launcher's sync didn't get through. Play waits for a sync's
    /// downloads, not its uploads: those carry on while the game starts.
    private func latestSaves() async {
        let pressed = Date()
        // The launcher left open while the headset slept loses its Steam connection: sign back in first (the saved
        // sign-in, a second or two), or the look at the cloud below can't see what another device saved meanwhile.
        if saveSync == nil, !(await launcher.cm.isLoggedOn), let creds = Keychain.load() {
            let launcher = self.launcher
            let back = await answer(within: Self.playStall) { try await launcher.logOn(creds) }
            NSLog("%@", "[launcher] Play: Steam connection was lost; signed back in: \(back != nil) after \(Self.seconds(since: pressed))")
        }
        if saveSync == nil, saves == .synced {
            saves = .syncing(CloudSync.Progress(stage: .checking))
            let launcher = self.launcher
            let changed = await answer(within: Self.quickCheckWait) { try await launcher.cloudChangedSinceLastSync() }
            NSLog("[launcher] Play: Steam Cloud %@", changed == nil ? "didn't answer in time; the saves synced at launch stay"
                                                    : changed! ? "has newer saves" : "has nothing newer")
            guard changed == true else { saves = .synced; return }
        }
        syncSavesInBackground()
        while !savesInPlace, saveSync != nil, Date().timeIntervalSince(max(pressed, savesMovedAt)) < Self.playStall {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if !savesInPlace, let running = saveSync {
            // Stops before the next file: a save is never half-written, and the rest come at the next launch.
            NSLog("[launcher] Play: saves stalled for %.0f s; the game starts with the saves here", Self.playStall)
            running.cancel()
            await running.value
        }
    }

    /// "1.2 s", for the log.
    private static func seconds(since t0: Date) -> String { String(format: "%.1f s", Date().timeIntervalSince(t0)) }

    /// `work`'s answer, or nil when it fails or hasn't answered within `seconds`. Then it's cancelled, and this
    /// returns at once even if `work` is slow to stop (a Steam logon waits out its own timeout).
    private func answer<T: Sendable>(within seconds: TimeInterval,
                                     _ work: @escaping @Sendable () async throws -> T) async -> T? {
        await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            let once = FirstAnswer(c)
            let task = Task.detached { once.give(try? await work()) }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                task.cancel()
                once.give(nil)
            }
        }
    }

    // MARK: Helpers

    static func friendly(_ error: Error) -> String {
        if let e = error as? SteamError {
            switch e {
            case .result(let r, _) where r == .invalidPassword: return "Wrong account name or password"
            case .result(let r, _) where r == .rateLimitExceeded: return "Too many tries. Wait a few minutes."
            case .result(let r, _) where r == .twoFactorCodeMismatch || r == .invalidLoginAuthCode: return "Wrong code"
            case .noServers, .disconnected, .notConnected: return "Can't reach Steam"
            default: return e.description
            }
        }
        return error.localizedDescription
    }
}

/// Hands on the first answer it's given; later ones are dropped.
private final class FirstAnswer<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var c: CheckedContinuation<T?, Never>?
    init(_ c: CheckedContinuation<T?, Never>) { self.c = c }
    func give(_ value: T?) {
        lock.lock()
        let c = self.c
        self.c = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

/// Extra running time after the app leaves the screen, ended exactly once.
@MainActor private final class BackgroundAssertion {
    var id = UIBackgroundTaskIdentifier.invalid
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

extension DownloadProgress {
    init(totalBytes: UInt64) {
        self.init()
        self.totalBytes = totalBytes
    }
}
