// Run with: python3 tools/tests/test_hand_motion.py
import Foundation
import simd

@main
enum HandMotionTests {
    static let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    static let dt = 1.0 / 90.0

    static func close(_ actual: SIMD3<Float>, _ expected: SIMD3<Float>,
                      tolerance: Float = 0.001, _ message: String) {
        precondition(actual.x.isFinite && actual.y.isFinite && actual.z.isFinite,
                     "\(message): nonfinite result \(actual)")
        precondition(simd_length(actual - expected) <= tolerance,
                     "\(message): expected \(expected), got \(actual)")
    }

    static func neutral(_ value: (linear: SIMD3<Float>, angular: SIMD3<Float>),
                        _ message: String) {
        close(value.linear, .zero, tolerance: 0, "\(message), linear")
        close(value.angular, .zero, tolerance: 0, "\(message), angular")
    }

    static func translation() {
        var motion = KleptonHandMotion()
        neutral(motion.update(position: .zero, orientation: identity, at: 0), "first sample")
        let speed = SIMD3<Float>(1, -2, 0.5)
        var result = (linear: SIMD3<Float>.zero, angular: SIMD3<Float>.zero)
        for frame in 1...90 {
            let time = Double(frame) * dt
            result = motion.update(position: speed * Float(time), orientation: identity, at: time)
        }
        close(result.linear, speed, "90 Hz translation")
        close(result.angular, .zero, "translation does not rotate")
    }

    static func rotation() {
        var motion = KleptonHandMotion()
        let base = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        let worldAxis = SIMD3<Float>(0, 1, 0)
        _ = motion.update(position: .zero, orientation: base, at: 0)
        var result = (linear: SIMD3<Float>.zero, angular: SIMD3<Float>.zero)
        for frame in 1...90 {
            let time = Double(frame) * dt
            var q = simd_quatf(angle: Float(time) * 2, axis: worldAxis) * base
            if frame.isMultiple(of: 2) { q = simd_quatf(vector: -q.vector) }
            result = motion.update(position: .zero, orientation: q, at: time)
        }
        close(result.angular, worldAxis * 2, "world-space rotation with quaternion sign flips")
        close(result.linear, .zero, "rotation does not translate")

        motion.reset()
        _ = motion.update(position: .zero, orientation: identity, at: 0)
        neutral(motion.update(position: .zero,
                              orientation: simd_quatf(vector: -identity.vector), at: dt),
                "quaternion sign alone is not motion")
    }

    static func discontinuities() {
        var motion = KleptonHandMotion()
        _ = motion.update(position: .zero, orientation: identity, at: 0)
        _ = motion.update(position: SIMD3<Float>(0.02, 0, 0), orientation: identity, at: dt)
        let far = SIMD3<Float>(5, 0, 0)
        neutral(motion.update(position: far, orientation: identity, at: 2 * dt), "position jump")
        neutral(motion.update(position: far, orientation: identity, at: 3 * dt), "jump rebases")
        let turned = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
        neutral(motion.update(position: far, orientation: turned, at: 4 * dt), "orientation jump")
        neutral(motion.update(position: far, orientation: turned, at: 5 * dt), "rotation rebases")
        neutral(motion.update(position: SIMD3<Float>(10, 0, 0), orientation: identity, at: 1),
                "tracking gap")
        motion.reset()
        neutral(motion.update(position: .zero, orientation: identity, at: 2), "explicit reset")
        neutral(motion.update(position: far, orientation: identity, at: 2), "duplicate timestamp")
        neutral(motion.update(position: .zero, orientation: identity, at: 1), "reversed timestamp")
        neutral(motion.update(position: far, orientation: identity, at: 1.000001), "tiny interval")
    }

    static func invalidSamples() {
        let invalid: [(SIMD3<Float>, simd_quatf, Double)] = [
            (SIMD3<Float>(.nan, 0, 0), identity, 1),
            (SIMD3<Float>(0, .infinity, 0), identity, 1),
            (.zero, simd_quatf(vector: SIMD4<Float>(0, 0, 0, .nan)), 1),
            (.zero, simd_quatf(vector: SIMD4<Float>(repeating: .infinity)), 1),
            (.zero, simd_quatf(vector: .zero), 1),
            (.zero, simd_quatf(vector: SIMD4<Float>(repeating: 1e30)), 1),
            (.zero, identity, .nan),
            (.zero, identity, .infinity),
        ]
        for (index, value) in invalid.enumerated() {
            var motion = KleptonHandMotion()
            _ = motion.update(position: .zero, orientation: identity, at: 0)
            _ = motion.update(position: SIMD3<Float>(0.01, 0, 0), orientation: identity, at: dt)
            neutral(motion.update(position: value.0, orientation: value.1, at: value.2),
                    "invalid sample \(index)")
            neutral(motion.update(position: SIMD3<Float>(5, 0, 0), orientation: identity, at: 2),
                    "invalid sample clears history \(index)")
        }

        var motion = KleptonHandMotion()
        _ = motion.update(position: .zero, orientation: identity, at: 0)
        neutral(motion.update(position: .zero,
                              orientation: simd_quatf(vector: identity.vector * 3), at: dt),
                "valid nonunit quaternion is normalized")
    }

    static func filteringAndBounds() {
        func translated(for duration: Double, rate: Double) -> SIMD3<Float> {
            var motion = KleptonHandMotion()
            _ = motion.update(position: .zero, orientation: identity, at: 0)
            var result = SIMD3<Float>.zero
            for frame in 1...Int((duration * rate).rounded()) {
                let time = Double(frame) / rate
                result = motion.update(position: SIMD3<Float>(Float(time), 0, 0),
                                       orientation: identity, at: time).linear
            }
            return result
        }
        close(translated(for: 0.1, rate: 90), translated(for: 0.1, rate: 120),
              "filter response is independent of display rate")

        var motion = KleptonHandMotion()
        _ = motion.update(position: .zero, orientation: identity, at: 0)
        var position = SIMD3<Float>.zero
        for frame in 1...360 {
            // Fast but valid motion, changing direction to exercise the filter.
            position += SIMD3<Float>(frame.isMultiple(of: 2) ? 0.125 : -0.125, 0, 0)
            let q = simd_quatf(angle: Float(frame) * 0.3, axis: SIMD3<Float>(0, 1, 0))
            let result = motion.update(position: position, orientation: q, at: Double(frame) * dt)
            precondition(simd_length(result.linear) <= 12, "linear velocity exceeds bound")
            precondition(simd_length(result.angular) <= 30, "angular velocity exceeds bound")
        }
    }

    static func main() {
        translation()
        rotation()
        discontinuities()
        invalidSamples()
        filteringAndBounds()
        print("Hand motion: 5 test groups passed")
    }
}
