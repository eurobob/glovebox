#if os(visionOS)
import ARKit
#endif
import Foundation
import simd

/// The launcher and compositor read the same preference before entering the game.
/// Other Klepton targets retain their existing input behavior.
enum KleptonHandInput {
    static var enabled: Bool {
        #if KL_ALYX_LAUNCHER
        return UserDefaults.standard.string(forKey: "glovebox.inputMode") != "sense"
        #else
        return false
        #endif
    }

    /// Run after kl_app_configure selects the normal gameinit script, before the guest starts.
    /// Gestures use a head-relative stick. Alyx's hand-oriented mode would rotate it again,
    /// potentially reversing strafe when the pinching palm faces back toward the player.
    static func configureLocomotion() {
        guard enabled else { return }
        let original = getenv("KL_LUA_INJECT").map { String(cString: $0) }
        do {
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            if let prepared = try prepareLocomotionInjection(original, cacheDirectory: cache, hands: true),
               prepared != original {
                setenv("KL_LUA_INJECT", prepared, 1)
                NSLog("[hands] Head-oriented locomotion hook prepared; saved movement preference kept")
            }
        } catch {
            // Preserve the original hook on failure; do not turn a movement correction into a boot failure.
            NSLog("[hands] Could not prepare locomotion hook: %@", error.localizedDescription)
        }
    }

    /// Preserve the configured script and append a live-player override. In the shipped Valve
    /// libserver, vr_movetype_set 2 sets MOVETYPE_VR_CONTINUOUS_HEAD (14), then audio opvars;
    /// it does not write hlvr_movetype_default. Apply after every spawn/load, since personal.cfg
    /// can restore the player's hand-oriented preference. Sense never installs this override.
    static func prepareLocomotionInjection(_ specification: String?, cacheDirectory: URL,
                                            hands: Bool) throws -> String? {
        guard hands, let specification else { return specification }
        let parts = specification.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, ["game/gameinit", "game/gameinit.lua"].contains(String(parts[0])),
              parts[1].hasPrefix("/") else { return specification }
        let original = try String(contentsOfFile: String(parts[1]), encoding: .utf8)
        let destination = cacheDirectory.appendingPathComponent("alyx-hands-gameinit.lua")
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try (original + "\n" + locomotionScript).write(to: destination, atomically: true, encoding: .utf8)
        return "\(parts[0])=\(destination.path)"
    }

    private static let locomotionScript = """
    -- Native-hand input is head-relative; change the live player, not saved options.
    ListenToGameEvent("player_activate", function()
      local world = Entities:First()
      if not world then return end
      world:SetThink(function()
        SendToServerConsole("vr_movetype_set 2")
        Msg("[hands] Head-oriented locomotion; saved movement=" .. tostring(Convars:GetStr("hlvr_movetype_default")) .. "\\n")
        return nil
      end, "klepton_hand_locomotion", 0.1)
    end, nil)
    """

    #if os(visionOS)
    static func sample(_ anchor: HandAnchor, head: simd_float4x4?) -> KleptonGestureSample? {
        guard anchor.isTracked else { return nil }
        let p = anchor.originFromAnchorTransform.columns.3
        let position = SIMD3<Float>(p.x, p.y, p.z)
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { return nil }

        func point(_ name: HandSkeleton.JointName) -> SIMD3<Float>? {
            guard let skeleton = anchor.handSkeleton else { return nil }
            let joint = skeleton.joint(name)
            guard joint.isTracked else { return nil }
            let p = joint.anchorFromJointTransform.columns.3
            let v = SIMD3<Float>(p.x, p.y, p.z)
            return v.x.isFinite && v.y.isFinite && v.z.isFinite ? v : nil
        }
        // The bend between the first and last finger bones is independent of
        // hand size and of the hand's rotation in the room.
        func curl(_ knuckle: HandSkeleton.JointName, _ base: HandSkeleton.JointName,
                  _ distal: HandSkeleton.JointName, _ tip: HandSkeleton.JointName) -> Float? {
            guard let a = point(knuckle), let b = point(base),
                  let c = point(distal), let d = point(tip),
                  simd_length(b - a) > 0.001, simd_length(d - c) > 0.001 else { return nil }
            return max(0, min(1, (1 - simd_dot(simd_normalize(b - a), simd_normalize(d - c))) * 0.5))
        }
        let mc = curl(.middleFingerKnuckle, .middleFingerIntermediateBase, .middleFingerIntermediateTip, .middleFingerTip)
        let rc = curl(.ringFingerKnuckle, .ringFingerIntermediateBase, .ringFingerIntermediateTip, .ringFingerTip)
        let lc = curl(.littleFingerKnuckle, .littleFingerIntermediateBase, .littleFingerIntermediateTip, .littleFingerTip)
        // A head sample is only needed to start a movement clutch. A missing
        // prediction, or looking vertically, must not disable menu selection.
        let right = head.map { SIMD3<Float>($0.columns.0.x, 0, $0.columns.0.z) } ?? .zero
        let forward = head.map { SIMD3<Float>(-$0.columns.2.x, 0, -$0.columns.2.z) } ?? .zero
        return KleptonGestureSample.fromFingertips(
            thumb: point(.thumbTip), index: point(.indexFingerTip),
            middle: point(.middleFingerTip), ring: point(.ringFingerTip), little: point(.littleFingerTip),
            middleCurl: mc, ringCurl: rc, littleCurl: lc, position: position,
            stickRight: right, stickForward: forward)
    }
    #endif
}
