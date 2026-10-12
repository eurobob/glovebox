import SwiftUI
import SteamLauncherKit
import GloveboxReports

/// Checks for newer upstream releases. This fork must be rebuilt on the Mac to retain experimental hand
/// controls; the original installer replaces it with upstream. Checked at most every few hours, with the last
/// answer kept so the notice works offline and clears when a build based on the new release is installed.
enum GloveboxUpdateCheck {
    /// The release this app was built from (alyx-demo/glovebox.json, written by the Mac's build).
    static let installed: String? = GloveboxBuildInfo.load().glovebox
    static let interval: TimeInterval = 6 * 3600
    private static let latestKey = "gloveboxLatestRelease"
    private static let checkedKey = "gloveboxLatestReleaseCheckedAt"

    /// The newer release, from the last answer kept; nil when this app is the latest.
    static var known: String? {
        GloveboxRelease.newer(UserDefaults.standard.string(forKey: latestKey), than: installed)
    }

    /// Asks GitHub again when the last answer is older than `interval`. A failed ask keeps the last answer and is
    /// tried again next time.
    static func refresh() async -> String? {
        guard let installed, GloveboxRelease.isRelease(installed) else { return nil }
        let d = UserDefaults.standard
        if Date().timeIntervalSince1970 - d.double(forKey: checkedKey) >= interval,
           let latest = await GloveboxRelease.fetchLatest() {
            d.set(latest, forKey: latestKey)
            d.set(Date().timeIntervalSince1970, forKey: checkedKey)
        }
        return known
    }
}

/// "Upstream Update" on glass beside the Glovebox chip. It never stands between the player and Play: what to
/// do is one look away, in a popover.
struct GloveboxUpdateButton: View {
    let version: String
    @State private var showSteps = false

    var body: some View {
        Button { showSteps = true } label: {
            Label {
                Text("Upstream Update")
            } icon: {
                Image(systemName: "arrow.down.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.black, Brand.orange)
            }
            .font(.title3.weight(.semibold))
            .padding(.leading, 12).padding(.trailing, 18)
            .frame(height: 44)
            .contentShape(.hoverEffect, .capsule)
            .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .glassBackgroundEffect(in: .capsule)
        .accessibilityLabel("Upstream Glovebox \(version) is available")
        .accessibilityHint("Shows how to update this experimental hand-controls build")
        .popover(isPresented: $showSteps, arrowEdge: .top) { GloveboxUpdateSteps(version: version) }
        .task {
            // The design-review screen with the popover open (DemoState).
            guard DemoState.current == .appupdatesteps else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            showSteps = true
        }
    }
}

/// Keep the fork's controls when incorporating an upstream release.
struct GloveboxUpdateSteps: View {
    let version: String

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                Image(systemName: "laptopcomputer.and.arrow.down")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Brand.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Upstream Glovebox \(version) is available").font(.title3.weight(.bold))
                    Text("Keep your experimental hand controls.").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                step(1, "Update this fork's source with the new upstream release on your Mac.")
                step(2, "Follow **docs/HAND-CONTROLS.md** to rebuild and install with the **same signing team and bundle ID**.")
            }
            Text("The original Mac installer's Install Update or Renew replaces this fork's experimental hand controls.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Label("Update in place to keep your game and saves. Don't uninstall.", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: 460, alignment: .leading)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("\(n)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 28, height: 28)
                .background(Brand.orange, in: .circle)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.body)
    }
}
