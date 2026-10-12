import ARKit
import QuartzCore
import simd

/// ARKit adapter for the independent finger skeleton and stable palm pose.
struct KleptonTrackedHand {
    static let names: [HandSkeleton.JointName] = [
        .wrist, .wrist, .thumbKnuckle, .thumbIntermediateBase, .thumbIntermediateTip, .thumbTip,
        .indexFingerMetacarpal, .indexFingerKnuckle, .indexFingerIntermediateBase, .indexFingerIntermediateTip, .indexFingerTip,
        .middleFingerMetacarpal, .middleFingerKnuckle, .middleFingerIntermediateBase, .middleFingerIntermediateTip, .middleFingerTip,
        .ringFingerMetacarpal, .ringFingerKnuckle, .ringFingerIntermediateBase, .ringFingerIntermediateTip, .ringFingerTip,
        .littleFingerMetacarpal, .littleFingerKnuckle, .littleFingerIntermediateBase, .littleFingerIntermediateTip, .littleFingerTip]
    private var palmInAnchor: KleptonJointPose?
    private var poseFilter = KleptonHandPoseFilter()
    private var boneFilters = Array(repeating: KleptonHandPoseFilter(), count: 31)

    mutating func reset(hand: Int) {
        poseFilter.reset()
        boneFilters = Array(repeating: KleptonHandPoseFilter(), count: 31)
        kl_hand_tracking_clear(Int32(hand))
    }

    mutating func update(_ anchor: HandAnchor, hand: Int, at time: Double) -> KleptonJointPose? {
        guard anchor.isTracked else { reset(hand: hand); return nil }
        let anchorPose = KleptonJointPose(anchor.originFromAnchorTransform)
        guard anchorPose.finite else { reset(hand: hand); return nil }
        let skeleton = anchor.handSkeleton
        let joints = skeleton.map { sk in Self.names.map { KleptonJointPose(sk.joint($0).anchorFromJointTransform) } }
        // Knuckle geometry is rigid in the palm. Cache it in anchor space so
        // a momentarily occluded knuckle never moves the pointer to the wrist.
        if let skeleton, let joints,
           [1, 7, 11, 12, 22].allSatisfy({ joints[$0].finite }),
           palmInAnchor == nil || [1, 7, 11, 12, 22].allSatisfy({ skeleton.joint(Self.names[$0]).isTracked }) {
            let forward = joints[12].p - joints[1].p
            let across = (joints[7].p - joints[22].p) * (hand == 0 ? 1 : -1)
            if simd_length(forward) > 0.02, simd_length(across) > 0.02 {
                let z = -simd_normalize(forward)
                let y = simd_cross(z, across)
                if simd_length(y) > 0.001 {
                    let up = simd_normalize(y), x = simd_normalize(simd_cross(up, z))
                    let sample = KleptonJointPose(p: (joints[11].p + joints[12].p) * 0.5,
                                                 q: simd_quatf(simd_float3x3(columns: (x, up, z))))
                    if let old = palmInAnchor {
                        palmInAnchor = KleptonJointPose(p: simd_mix(old.p, sample.p, SIMD3(repeating: 0.03)),
                                                       q: simd_slerp(old.q, sample.q, 0.03))
                    } else { palmInAnchor = sample }
                }
            }
        }
        if palmInAnchor == nil {
            // Start even if the little knuckle is occluded. This is ALVR's
            // wrist-to-hand basis; measured palm geometry refines it above.
            let correction = hand == 0
                ? simd_quatf(from: SIMD3<Float>(1, 0, 0), to: SIMD3<Float>(-1, 0, 0))
                    * simd_quatf(from: SIMD3<Float>(1, 0, 0), to: SIMD3<Float>(0, 0, -1))
                : simd_quatf(from: SIMD3<Float>(0, 0, 1), to: SIMD3<Float>(0, 0, -1))
                    * simd_quatf(from: SIMD3<Float>(1, 0, 0), to: SIMD3<Float>(0, 0, 1))
            let offset: SIMD3<Float>
            if let joints, joints[11].finite, joints[12].finite {
                offset = (joints[11].p + joints[12].p) * 0.5
            } else { offset = .zero }
            palmInAnchor = KleptonJointPose(p: offset, q: correction)
        }
        guard let palmInAnchor else { return nil }
        let root = poseFilter.update(anchorPose.times(palmInAnchor), at: time)
        // A missing finger must never cancel the valid palm/aim pose or an
        // unrelated gesture. Skeleton loss only invalidates skeletal data.
        guard let joints, joints.allSatisfy(\.finite) else {
            kl_hand_tracking_clear(Int32(hand))
            return root
        }
        // Apply the filtered rigid hand motion to the skeleton too, preserving
        // wrist/pointer alignment. Finger articulation remains independent.
        let filteredAnchor = root.times(KleptonJointPose.identity.relative(to: palmInAnchor))
        // ARKit also supplies inferred transforms for occluded joints. Keep
        // those visual estimates; gesture sampling separately requires the
        // relevant fingertips to be tracked before it can press anything.
        let world = joints.map { filteredAnchor.times($0) }
        guard var bones = KleptonHandSkeleton.convert(world, root: root, hand: hand) else {
            kl_hand_tracking_clear(Int32(hand)); return root
        }
        for i in 1..<26 { bones[i] = boneFilters[i].update(bones[i], at: time, minimumHz: 12) }
        // Derive helpers from the filtered chain so they cannot disagree.
        let model = KleptonHandSkeleton.toModel(bones)
        for f in 0..<5 { bones[26 + f] = model[KleptonHandSkeleton.tips[f] - 1] }
        let data = bones.flatMap(\.floats)
        let curls = KleptonHandSkeleton.curls(joints), splays = KleptonHandSkeleton.splays(joints)
        data.withUnsafeBufferPointer { b in
            curls.withUnsafeBufferPointer { c in
                splays.withUnsafeBufferPointer { s in
                    kl_hand_tracking_publish(Int32(hand), b.baseAddress, c.baseAddress, s.baseAddress, CACurrentMediaTime())
                }
            }
        }
        return root
    }
}
