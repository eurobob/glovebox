import Foundation
import simd

/// Coordinate conversion follows ALVR's ARKit/OpenXR/SteamVR joint bases.
/// See THIRD-PARTY-HAND-TRACKING.txt for its MIT notices and source links.
/// Unlike a curl animation, every finger joint keeps its measured translation
/// and rotation. All poses below use metres and quaternions in xyzw order.
struct KleptonJointPose {
    var p: SIMD3<Float>
    var q: simd_quatf
    static let identity = Self(p: .zero, q: simd_quatf(real: 1, imag: .zero))
    init(p: SIMD3<Float>, q: simd_quatf) {
        self.p = p
        self.q = simd_length_squared(q.vector) > 1e-10 ? simd_normalize(q)
            : simd_quatf(vector: SIMD4(repeating: .nan))
    }
    init(_ m: simd_float4x4) {
        self.init(p: SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z), q: simd_quatf(m))
    }
    var finite: Bool { p.x.isFinite && p.y.isFinite && p.z.isFinite && q.vector.x.isFinite
        && q.vector.y.isFinite && q.vector.z.isFinite && q.vector.w.isFinite }
    func times(_ b: Self) -> Self { Self(p: p + q.act(b.p), q: q * b.q) }
    func relative(to a: Self) -> Self { Self(p: a.q.inverse.act(p - a.p), q: a.q.inverse * q) }
    var floats: [Float] { [p.x, p.y, p.z, q.imag.x, q.imag.y, q.imag.z, q.real] }
}

struct KleptonHandPoseFilter {
    private var previous: KleptonJointPose?
    private var time: Double?
    mutating func reset() { previous = nil; time = nil }
    mutating func update(_ raw: KleptonJointPose, at t: Double,
                         minimumHz: Float = 4) -> KleptonJointPose {
        guard raw.finite, t.isFinite else { reset(); return raw }
        guard let old = previous, let last = time, t > last, t - last < 0.12 else {
            previous = raw; time = t; return raw
        }
        let dt = Float(t - last)
        // A slow pointer is damped; deliberate fast motion opens the filter.
        let speed = simd_distance(raw.p, old.p) / dt
        let angle = 2 * acos(min(1, abs(simd_dot(old.q.vector, raw.q.vector))))
        func alpha(_ hz: Float) -> Float { 1 - exp(-2 * .pi * hz * dt) }
        let p = simd_mix(old.p, raw.p, SIMD3(repeating: alpha(min(35, minimumHz + 12 * speed))))
        let q = simd_slerp(old.q, raw.q, alpha(min(35, minimumHz + 0.8 * angle / dt)))
        let result = KleptonJointPose(p: p, q: q)
        previous = result; time = t
        return result
    }
}

enum KleptonHandSkeleton {
    static let parents = [-1, 0, 1, 2, 3, 4, 1, 6, 7, 8, 9, 1, 11, 12, 13, 14,
                          1, 16, 17, 18, 19, 1, 21, 22, 23, 24, 0, 0, 0, 0, 0]
    static let tips = [5, 10, 15, 20, 25]

    /// Source indices 1...25 are ARKit wrist, thumb's four joints and each
    /// finger's five joints. Index 0 is reserved for the game pose/root.
    static func convert(_ source: [KleptonJointPose], root: KleptonJointPose,
                        hand: Int) -> [KleptonJointPose]? {
        guard source.count == 26, root.finite, source.allSatisfy(\.finite),
              hand == 0 || hand == 1 else { return nil }
        // The same basis chain as ALVR WorldTracker.handAnchorToSkeleton,
        // then tracking.rs local_pose. Use the same antiparallel-vector
        // constructor so the rotation axis is explicit in the tested chain.
        let appleToXR = simd_quatf(from: SIMD3<Float>(1, 0, 0), to: SIMD3<Float>(0, 0, 1))
            * (hand == 1
               ? simd_quatf(from: SIMD3<Float>(0, 0, 1), to: SIMD3<Float>(0, 0, -1))
               : simd_quatf(from: SIMD3<Float>(1, 0, 0), to: SIMD3<Float>(-1, 0, 0)))
        // C maps an OpenXR parent-local vector to the SteamVR joint frame.
        let c = hand == 0
            ? simd_float3x3(columns: (SIMD3(0, 0, -1), SIMD3(0, -1, 0), SIMD3(-1, 0, 0)))
            : simd_float3x3(columns: (SIMD3(0, 0, -1), SIMD3(0, 1, 0), SIMD3(1, 0, 0)))
        let xrToValve = simd_quatf(c).inverse
        let wristFix = simd_quatf(angle: -.pi / 2, axis: SIMD3(0, 1, 0))
            * simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
        var model = Array(repeating: KleptonJointPose.identity, count: 31)
        for i in 1...25 {
            var world = source[i]
            world.q = world.q * appleToXR * (i == 1 ? wristFix : simd_quatf(real: 1, imag: .zero)) * xrToValve
            model[i] = world.relative(to: root)
        }
        // Valve's auxiliary bones are root-parented copies of the last joint
        // before each tip, not guessed curled poses.
        for f in 0..<5 { model[26 + f] = model[tips[f] - 1] }
        return model.enumerated().map { i, pose in
            parents[i] < 0 ? pose : pose.relative(to: model[parents[i]])
        }
    }

    static func toModel(_ local: [KleptonJointPose]) -> [KleptonJointPose] {
        var model = local
        for i in 1..<min(local.count, parents.count) { model[i] = model[parents[i]].times(local[i]) }
        return model
    }

    static func curls(_ source: [KleptonJointPose]) -> [Float] {
        zip([2, 7, 12, 17, 22], tips).map { base, tip in
            let a = source[base + 1].p - source[base].p
            let b = source[tip].p - source[tip - 1].p
            guard simd_length(a) > 0.001, simd_length(b) > 0.001 else { return 0 }
            return max(0, min(1, (1 - simd_dot(simd_normalize(a), simd_normalize(b))) * 0.5))
        }
    }

    static func splays(_ source: [KleptonJointPose]) -> [Float] {
        let bases = [2, 7, 12, 17, 22]
        let directions = zip(bases, tips).map { base, tip in source[tip].p - source[base].p }
        return (0..<4).map { i in
            let a = directions[i], b = directions[i + 1]
            guard simd_length(a) > 0.001, simd_length(b) > 0.001 else { return 0 }
            return min(1, acos(max(-1, min(1, simd_dot(simd_normalize(a), simd_normalize(b))))) / (.pi / 2))
        }
    }
}
