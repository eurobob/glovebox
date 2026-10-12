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
        guard anchor.isTracked, let skeleton = anchor.handSkeleton, let head else { return nil }
        func point(_ name: HandSkeleton.JointName) -> SIMD3<Float>? {
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
        guard let thumb = point(.thumbTip), let index = point(.indexFingerTip),
              let middle = point(.middleFingerTip), let ring = point(.ringFingerTip),
              let little = point(.littleFingerTip),
              let mc = curl(.middleFingerKnuckle, .middleFingerIntermediateBase, .middleFingerIntermediateTip, .middleFingerTip),
              let rc = curl(.ringFingerKnuckle, .ringFingerIntermediateBase, .ringFingerIntermediateTip, .ringFingerTip),
              let lc = curl(.littleFingerKnuckle, .littleFingerIntermediateBase, .littleFingerIntermediateTip, .littleFingerTip)
        else { return nil }
        let p = anchor.originFromAnchorTransform.columns.3
        let right = head.columns.0
        let forward = -head.columns.2
        return KleptonGestureSample(
            indexPinch: simd_distance(thumb, index),
            // A thumb touching a folded finger during a fist is not a button.
            middlePinch: rc < 0.5 && lc < 0.5 ? simd_distance(thumb, middle) : 0.2,
            ringPinch: mc < 0.5 && lc < 0.5 ? simd_distance(thumb, ring) : 0.2,
            littlePinch: mc < 0.5 && rc < 0.5 ? simd_distance(thumb, little) : 0.2,
            gripCurl: min(mc, rc, lc),
            position: SIMD3<Float>(p.x, p.y, p.z),
            stickRight: SIMD3<Float>(right.x, 0, right.z),
            stickForward: SIMD3<Float>(forward.x, 0, forward.z))
    }
}
