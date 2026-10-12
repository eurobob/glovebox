import Foundation
import simd

@main struct HandSkeletonTests {
    static var checks = 0
    static func require(_ condition: Bool, _ text: String) {
        checks += 1
        if !condition { fatalError(text) }
    }
    static func near(_ a: KleptonJointPose, _ b: KleptonJointPose, _ text: String) {
        require(simd_distance(a.p, b.p) < 0.00002, text + " position")
        require(abs(simd_dot(a.q.vector, b.q.vector)) > 0.99999, text + " rotation")
    }
    static func main() {
        let root = KleptonJointPose(p: SIMD3(0.2, 1.3, -0.4),
                                   q: simd_quatf(angle: 0.7, axis: normalize(SIMD3(1, 2, 3))))
        // Deliberately asymmetric joints: catches chirality, quaternion order,
        // world/local confusion, and using one finger's curl for all fingers.
        var joints: [KleptonJointPose] = (0..<26).map { i in
            let p = SIMD3<Float>(Float(i) * 0.001, Float(i % 5) * 0.012, -Float(i) * 0.008)
            let axis = simd_normalize(SIMD3<Float>(1, Float(i % 3 + 1), 0.3))
            return KleptonJointPose(p: p, q: simd_quatf(angle: Float(i) * 0.07, axis: axis))
        }
        for hand in 0...1 {
            let local = KleptonHandSkeleton.convert(joints, root: root, hand: hand)!
            require(local.count == 31, "31 Valve bones")
            near(local[0], .identity, "identity root")
            let model = KleptonHandSkeleton.toModel(local)
            for i in 1...25 {
                require(simd_distance(root.times(model[i]).p, joints[i].p) < 0.00002,
                        "measured joint position survives hierarchy \(hand)/\(i)")
            }
            for f in 0..<5 { near(model[26 + f], model[KleptonHandSkeleton.tips[f] - 1], "root auxiliary") }

            // An independent ALVR local_pose transcription checks the basis
            // of finger rotations/translations, not merely a round trip.
            let a = simd_quatf(from: SIMD3<Float>(1, 0, 0), to: SIMD3<Float>(0, 0, 1))
                * (hand == 1
                   ? simd_quatf(from: SIMD3<Float>(0, 0, 1), to: SIMD3<Float>(0, 0, -1))
                   : simd_quatf(from: SIMD3<Float>(1, 0, 0), to: SIMD3<Float>(-1, 0, 0)))
            for i in [3, 4, 5, 7, 8, 9, 10, 12, 13, 14, 15, 17, 18, 19, 20, 22, 23, 24, 25] {
                let parent = joints[KleptonHandSkeleton.parents[i]], child = joints[i]
                let pq = parent.q * a, cq = child.q * a
                let o = pq.inverse * cq, p = pq.inverse.act(child.p - parent.p)
                let q = hand == 0
                    ? simd_quatf(ix: -o.imag.z, iy: -o.imag.y, iz: -o.imag.x, r: o.real)
                    : simd_quatf(ix: o.imag.z, iy: o.imag.y, iz: -o.imag.x, r: o.real)
                let converted: SIMD3<Float> = hand == 0 ? SIMD3(-p.z, -p.y, -p.x) : SIMD3(p.z, p.y, -p.x)
                near(local[i], KleptonJointPose(p: converted, q: q), "ALVR local basis \(hand)/\(i): \(local[i].p) versus \(converted)")
            }
            // Turning or moving the whole hand cannot change its articulation.
            let worldMove = KleptonJointPose(p: SIMD3(-3, 0.5, 2), q: simd_quatf(angle: 1.1, axis: SIMD3(0, 1, 0)))
            let moved = KleptonHandSkeleton.convert(joints.map { worldMove.times($0) },
                                                   root: worldMove.times(root), hand: hand)!
            for i in 0..<31 { near(local[i], moved[i], "world motion invariance") }
            // A single ring joint must not animate middle/index/thumb/pinky.
            var bent = joints
            bent[19].q *= simd_quatf(angle: 0.6, axis: SIMD3(0, 0, 1))
            let changed = KleptonHandSkeleton.convert(bent, root: root, hand: hand)!
            for i in [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 21, 22, 23, 24, 25] {
                near(local[i], changed[i], "independent finger")
            }
            require(abs(simd_dot(local[19].q.vector, changed[19].q.vector)) < 0.99, "ring articulation arrives")
        }
        joints[10].p.x = .nan
        require(KleptonHandSkeleton.convert(joints, root: root, hand: 0) == nil, "invalid joint rejected")

        var filter = KleptonHandPoseFilter()
        _ = filter.update(.identity, at: 0)
        var squared: Float = 0
        for i in 1...180 {
            let raw = KleptonJointPose(p: SIMD3(i % 2 == 0 ? 0.002 : -0.002, 0, 0), q: simd_quatf(real: 1, imag: .zero))
            let output = filter.update(raw, at: Double(i) / 90)
            if i > 30 { squared += output.p.x * output.p.x }
        }
        require(sqrt(squared / 150) < 0.0007, "stationary 2mm jitter reduced below0.7mm")
        filter.reset()
        _ = filter.update(.identity, at: 0)
        var last = KleptonJointPose.identity
        for i in 1...90 {
            last = filter.update(KleptonJointPose(p: SIMD3(Float(i) / 90, 0, 0), q: simd_quatf(real: 1, imag: .zero)), at: Double(i) / 90)
        }
        require(1 - last.p.x < 0.012, "fast1m/s movement lags less than12mm")
        let reacquired = KleptonJointPose(p: SIMD3(2, 0, 0), q: simd_quatf(angle: 1, axis: SIMD3(0, 1, 0)))
        near(filter.update(reacquired, at: 2), reacquired, "gap resets stale smoothing")
        let negated = KleptonJointPose(p: reacquired.p, q: simd_quatf(vector: -reacquired.q.vector))
        near(filter.update(negated, at: 2.01), reacquired, "quaternion sign cannot cause flip")
        print("\(checks) hand skeleton and pose checks passed")
    }
}
