import Foundation
import simd

/// Estimates motion from successive tracked grip poses for experimental hand input.
/// Positions and orientations must share tracking space; timestamps must be the
/// corresponding frame presentation times. Reset whenever tracking or input source changes.
/// This is a single-writer value type, intended to live on the compositor thread.
struct KleptonHandMotion {
    private struct Sample {
        var position: SIMD3<Float>
        var orientation: simd_quatf
        var time: Double
    }

    private var previous: Sample?
    private var linear: SIMD3<Float> = .zero
    private var angular: SIMD3<Float> = .zero

    // Conservative limits reject tracking jumps instead of turning them into throws.
    private static let maximumLinearSpeed: Float = 12 // m/s
    private static let maximumAngularSpeed: Float = 30 // rad/s
    private static let maximumInterval = 0.1
    private static let minimumInterval = 0.0001
    private static let responseTime = 0.018 // seconds; independent of display rate

    mutating func reset() {
        previous = nil
        linear = .zero
        angular = .zero
    }

    mutating func update(position: SIMD3<Float>, orientation: simd_quatf,
                         at time: Double) -> (linear: SIMD3<Float>, angular: SIMD3<Float>) {
        let q = orientation.vector
        let normSquared = simd_length_squared(q)
        guard Self.finite(position), q.x.isFinite, q.y.isFinite,
              q.z.isFinite, q.w.isFinite, time.isFinite,
              normSquared.isFinite, normSquared > 1e-8 else {
            reset()
            return (.zero, .zero)
        }

        let current = Sample(position: position,
                             orientation: simd_quatf(vector: q / sqrt(normSquared)),
                             time: time)
        let last = previous
        previous = current

        guard let last else { return neutral() }
        let dt = time - last.time
        guard dt >= Self.minimumInterval, dt <= Self.maximumInterval else {
            return neutral()
        }

        let rawLinear = (position - last.position) / Float(dt)
        // Left multiplication expresses angular velocity in tracking/world space.
        // q and -q denote the same orientation; choose the shorter rotation arc.
        var delta = current.orientation * last.orientation.inverse
        if delta.real < 0 { delta = simd_quatf(vector: -delta.vector) }
        let sineHalfAngle = simd_length(delta.imag)
        let rawAngular: SIMD3<Float>
        if sineHalfAngle > 1e-7 {
            let angle = 2 * atan2(sineHalfAngle, max(0, delta.real))
            rawAngular = delta.imag * (angle / (sineHalfAngle * Float(dt)))
        } else {
            // Ignore quaternion multiplication roundoff at an unchanged pose.
            rawAngular = .zero
        }

        guard Self.finite(rawLinear), Self.finite(rawAngular),
              simd_length(rawLinear) <= Self.maximumLinearSpeed,
              simd_length(rawAngular) <= Self.maximumAngularSpeed else {
            // Keep the new pose as the baseline, but discard the filter's old motion.
            // Both channels reset together: a tracker jump is not a physical movement.
            return neutral()
        }

        let alpha = Float(-expm1(-dt / Self.responseTime))
        linear += alpha * (rawLinear - linear)
        angular += alpha * (rawAngular - angular)
        return (linear, angular)
    }

    private mutating func neutral() -> (linear: SIMD3<Float>, angular: SIMD3<Float>) {
        linear = .zero
        angular = .zero
        return (.zero, .zero)
    }

    private static func finite(_ v: SIMD3<Float>) -> Bool {
        v.x.isFinite && v.y.isFinite && v.z.isFinite
    }
}
