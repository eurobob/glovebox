import ARKit
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
}
