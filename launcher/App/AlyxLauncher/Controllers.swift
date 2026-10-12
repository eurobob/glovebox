import SwiftUI
import UIKit
import GameController
import ARKit

/// Shared with the game's input bridge through UserDefaults. This experimental fork starts in
/// hands mode; choosing Sense restores the original controller requirements.
enum LauncherInputMode: String, CaseIterable, Identifiable {
    case hands, sense

    static let defaultsKey = "glovebox.inputMode"
    static var saved: Self {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .hands
    }

    var id: String { rawValue }
    var title: String { self == .hands ? "Hands (Experimental)" : "PS VR2 Sense" }
}

/// Tracking permissions and the Sense controllers connected right now.
struct ControllerState: Equatable {
    enum Access: Equatable { case notAsked, allowed, denied }
    /// Sense controllers connected right now (the game needs both).
    var connected = 0
    var access = Access.notAsked
    var handAccess = Access.notAsked
}

/// What stands between the player and Play.
enum ControllerIssue: Equatable {
    case trackingDenied
    case notConnected(Int)
    case handTrackingDenied
    case handTrackingUnavailable
    case senseUnavailable
}

extension LauncherModel {
    /// A host with no controllers to check can turn this off for Sense mode.
    static var requiresControllers = true

    /// Other tracking permissions to ask for together with the controllers' at Play, so every
    /// system dialog appears over the launcher rather than as the game starts (e.g. `.handTracking`
    /// while the game still tracks hands).
    static var alsoAsk: [ARKitSession.AuthorizationType] = []

    private static let arSession = ARKitSession()

    var controllerIssue: ControllerIssue? {
        switch inputMode {
        case .hands:
            guard HandTrackingProvider.isSupported else { return .handTrackingUnavailable }
            return controllers.handAccess == .denied ? .handTrackingDenied : nil
        case .sense:
            guard Self.requiresControllers else { return nil }
            guard #available(visionOS 26.0, *) else { return .senseUnavailable }
            if controllers.access == .denied { return .trackingDenied }
            if controllers.connected < 2 { return .notConnected(controllers.connected) }
            return nil
        }
    }

    /// Counts the Sense controllers now and whenever one connects or drops, so Play unlocks by
    /// itself the moment the second one turns on.
    func watchControllers() {
        refreshControllerAccess()
        guard #available(visionOS 26.0, *) else { return }
        countControllers()
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                let model = self
                MainActor.assumeIsolated { model?.countControllers() }
            }
        }
    }

    @available(visionOS 26.0, *)
    private func countControllers() {
        controllers.connected = GCController.controllers()
            .filter { $0.productCategory == GCProductCategorySpatialController }.count
        NSLog("[launcher] Sense controllers connected: \(controllers.connected)")
    }

    /// The permission as it stands, without asking: at start, and on coming back from Settings.
    func refreshControllerAccess() {
        guard DemoState.current == nil else { return }
        Task {
            var permissions: [ARKitSession.AuthorizationType] = [.handTracking]
            if #available(visionOS 26.0, *) { permissions.append(.accessoryTracking) }
            let status = await Self.arSession.queryAuthorization(for: permissions)
            controllers.handAccess = .init(status[.handTracking])
            if #available(visionOS 26.0, *) {
                controllers.access = .init(status[.accessoryTracking])
            }
        }
    }

    /// Asks for the selected input's tracking at Play, so its dialog appears over the launcher.
    func allowControllerTracking() async -> Bool {
        guard DemoState.current == nil else { return true }
        switch inputMode {
        case .hands:
            guard HandTrackingProvider.isSupported else { return false }
            let status = await Self.arSession.requestAuthorization(for: [.handTracking])
            controllers.handAccess = .init(status[.handTracking])
            return controllers.handAccess == .allowed
        case .sense:
            guard Self.requiresControllers else { return true }
            guard #available(visionOS 26.0, *) else { return false }
            let status = await Self.arSession.requestAuthorization(for: [.accessoryTracking] + Self.alsoAsk)
            controllers.access = .init(status[.accessoryTracking])
            return controllers.access == .allowed
        }
    }
}

private extension ControllerState.Access {
    init(_ status: ARKitSession.AuthorizationStatus?) {
        switch status {
        case .allowed?: self = .allowed
        case .denied?: self = .denied
        default: self = .notAsked
        }
    }
}

/// Available before Play, with the gestures used by the experimental hand input bridge.
struct InputControlsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let mode: LauncherInputMode

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text(mode.title).font(.title.weight(.bold))
                Spacer()
                Button("Done") { dismiss() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if mode == .hands {
                        Text("Keep both hands in view. Pinch a fingertip to your thumb, then release to reset. For middle, ring and little pinches, keep the other two fingers open.")
                            .foregroundStyle(.secondary)
                        control("Index + thumb", "Trigger: select and fire")
                        control("Curl middle, ring and little fingers", "Grip: hold and grab")
                        control("Middle + thumb, then move your hand", "Virtual stick: left hand moves; right hand turns. Pull the right hand back to teleport.")
                        control("Hold middle + thumb still for 0.8 seconds", "Click that hand's virtual stick")
                        control("Ring + thumb", "Left hand: X · Right hand: A")
                        control("Little + thumb", "Left hand: tap and release for Y · Right hand: B")
                        control("Hold left little + thumb for 0.8 seconds", "Open the game menu")
                        Text("Release the middle pinch to stop moving. Re-pinch to set a new stick center. Gesture controls are experimental and may need practice.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("Turn on both controllers with their PS buttons. Pair them in Settings › Bluetooth the first time.")
                            .foregroundStyle(.secondary)
                        control("Triggers", "Select and fire")
                        control("Grip buttons", "Hold and grab")
                        control("Thumbsticks", "Move, turn and teleport using the game's bindings")
                        control("Face buttons", "A / B / X / Y actions using the game's bindings")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(36)
        .frame(width: 720, height: 650)
    }

    private func control(_ gesture: String, _ action: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(gesture).font(.headline)
            Text(action).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// In place of the saves line while Play waits: the selected input and what to do.
struct ControllerStatus: View {
    let issue: ControllerIssue
    let connected: Int

    var body: some View {
        HStack(spacing: 20) {
            if issue == .handTrackingDenied || issue == .handTrackingUnavailable {
                Image(systemName: "hand.raised.fingers.spread.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
            } else {
                SenseControllers(on: connected, waiting: issue != .trackingDenied && issue != .senseUnavailable)
                    .overlay(alignment: .bottomTrailing) {
                        if issue == .trackingDenied {
                            Image(systemName: "lock.fill")
                                .font(.caption.weight(.bold))
                                .padding(6)
                                .background(.orange, in: .circle)
                                .offset(x: 6, y: 4)
                        }
                    }
            }
            VStack(alignment: .leading, spacing: 4) {
                switch issue {
                case .notConnected(let n):
                    Text(n == 1 ? "Turn on the other controller" : "Turn on both controllers")
                        .font(.title3.weight(.semibold))
                    Text(n == 1 ? "Press its PS button." : "Press the PS button on each.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("First time? Pair them in Settings › Bluetooth.")
                        .font(.callout).foregroundStyle(.tertiary)
                case .trackingDenied, .handTrackingDenied:
                    Text(issue == .handTrackingDenied ? "Hand tracking is off" : "Controller tracking is off")
                        .font(.title3.weight(.semibold))
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
                case .handTrackingUnavailable:
                    Text("Hand tracking is unavailable")
                        .font(.title3.weight(.semibold))
                    Text("Use a supported Vision Pro or choose PS VR2 Sense.")
                        .font(.callout).foregroundStyle(.secondary)
                case .senseUnavailable:
                    Text("Sense controllers need visionOS 26 or later")
                        .font(.title3.weight(.semibold))
                    Text("Choose Hands or update visionOS.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: connected)
    }
}

/// Two PS VR2 Sense controllers, drawn: lit when connected, softly pulsing while they're awaited.
struct SenseControllers: View {
    /// How many are on: the left one lights first.
    var on: Int
    var waiting = true
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            SenseController(left: true).foregroundStyle(.white.opacity(level(lit: on >= 1)))
            SenseController(left: false).foregroundStyle(.white.opacity(level(lit: on >= 2)))
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever()) { pulse = true }
        }
    }

    private func level(lit: Bool) -> Double {
        if lit { return 1 }
        return waiting && pulse ? 0.5 : 0.2
    }
}

/// One controller: the ring that wraps the back of the hand, over a grip that leans outward.
private struct SenseController: View {
    var left: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Circle()
                .trim(from: 0.14, to: 0.86)
                .stroke(style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(90))
                .frame(width: 30, height: 30)
            Capsule()
                .frame(width: 10, height: 26)
                .offset(y: 25)
        }
        .rotationEffect(.degrees(left ? -14 : 14))
        .frame(width: 34, height: 56)
    }
}
