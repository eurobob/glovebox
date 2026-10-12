// Pure hand-input interpretation. Kept independent of ARKit and OVR so the
// noisy-input and tracking-loss rules can be tested on the Mac.
import Foundation
import simd

struct KleptonGestureSample {
    // Thumb-to-fingertip distances, in metres.
    var indexPinch: Float
    var middlePinch: Float
    var ringPinch: Float
    var littlePinch: Float
    // Mean curl of the middle, ring and little fingers: open = 0, fist = 1.
    var gripCurl: Float
    var position: SIMD3<Float>
    // Head-relative world-space axes. The clutch freezes these at activation.
    var stickRight: SIMD3<Float>
    var stickForward: SIMD3<Float>
}

struct KleptonGestureOutput {
    var trigger: Float = 0
    var grip: Float = 0
    var stick: SIMD2<Float> = .zero
    var primary = false
    var secondary = false
    var stickClick = false
    var menu = false

    static let neutral = KleptonGestureOutput()
}

/// One instance per hand. Hand 0 is left; hand 1 is right.
///
/// Index pinch is trigger; middle pinch clutches a virtual stick; ring pinch
/// holds A/X; little pinch holds B on the right. On the left, a short little
/// pinch emits Y on release, or a 0.8-second hold emits Menu once instead.
/// Holding a middle pinch still for 0.8 seconds emits one stick click. Moving
/// outside the stick dead zone cancels that click for the rest of the clutch.
/// These momentary button presses last 120 ms so a slower guest input poll can
/// observe them. Tracking loss cancels them immediately.
///
/// Trigger and grip are deliberately digital, represented as 0/1 floats.
/// Pinch hysteresis avoids flickering fire around an analog press threshold.
struct KleptonHandGestures {
    private enum Pinch: CaseIterable {
        case index, middle, ring, little

        func distance(in sample: KleptonGestureSample) -> Float {
            switch self {
            case .index: return sample.indexPinch
            case .middle: return sample.middlePinch
            case .ring: return sample.ringPinch
            case .little: return sample.littlePinch
            }
        }
    }

    private static let pinchDown: Float = 0.023
    private static let pinchUp: Float = 0.032
    private static let gripDown: Float = 0.80
    private static let gripUp: Float = 0.55
    private static let debounce: Double = 0.05
    private static let longPress: Double = 0.8
    private static let pulseDuration: Double = 0.12
    private static let stickDeadZone: Float = 0.01
    private static let stickFullScale: Float = 0.08

    private var armed = false
    private var lastTime: Double?
    private var lastHand: Int?
    private var candidate: Pinch?
    private var candidateSince: Double = 0
    private var active: Pinch?
    private var activeSince: Double = 0
    private var holdDidFire = false
    private var middleStayedNeutral = true
    private var stickOrigin = SIMD3<Float>.zero
    private var stickRight = SIMD3<Float>.zero
    private var stickForward = SIMD3<Float>.zero
    private var gripActive = false
    private var gripSince: Double?
    private var gripNeedsRelax = false
    private var secondaryPulseUntil: Double = 0
    private var menuPulseUntil: Double = 0
    private var stickClickPulseUntil: Double = 0

    mutating func update(sample: KleptonGestureSample?, at time: Double,
                         hand: Int) -> KleptonGestureOutput {
        guard let sample, Self.valid(sample), time.isFinite, time >= 0,
              hand == 0 || hand == 1,
              lastTime.map({ time >= $0 }) ?? true,
              lastHand.map({ hand == $0 }) ?? true else {
            self = Self()
            return .neutral
        }
        lastTime = time
        lastHand = hand

        // Startup, loss of tracking, and invalid samples all require a fresh
        // open hand. Reappearing while pinched must never resume movement/fire.
        guard armed else {
            armed = Pinch.allCases.allSatisfy {
                $0.distance(in: sample) >= Self.pinchUp
            } && sample.gripCurl <= Self.gripUp
            return .neutral
        }

        var output = KleptonGestureOutput.neutral
        var released = false
        if let active, active.distance(in: sample) >= Self.pinchUp {
            if active == .little, hand == 0, !holdDidFire {
                // Also classify correctly if the release frame crosses the
                // long-press boundary without an intervening held frame.
                if time - activeSince >= Self.longPress {
                    menuPulseUntil = time + Self.pulseDuration
                } else {
                    secondaryPulseUntil = time + Self.pulseDuration
                }
            }
            self.active = nil
            candidate = nil
            holdDidFire = false
            stickOrigin = .zero
            stickRight = .zero
            stickForward = .zero
            released = true
        }

        let hasPulse = time < secondaryPulseUntil || time < menuPulseUntil
            || time < stickClickPulseUntil
        // Finishing a momentary press precedes recognizing the next pinch, so
        // changing fingers quickly cannot overlap two exclusive button presses.
        if active == nil, !released, !hasPulse {
            // A stable tie goes to index, then middle, ring, little. Once
            // active, another finger cannot steal the pinch until release.
            let nearest = Pinch.allCases.filter {
                $0.distance(in: sample) <= Self.pinchDown
            }.min { $0.distance(in: sample) < $1.distance(in: sample) }
            if nearest != candidate {
                candidate = nearest
                candidateSince = time
            }
            if let candidate, time - candidateSince >= Self.debounce {
                active = candidate
                activeSince = candidateSince
                holdDidFire = false
                middleStayedNeutral = true
                if candidate == .middle {
                    stickOrigin = sample.position
                    (stickRight, stickForward) = Self.horizontalAxes(sample)
                }
                self.candidate = nil
            }
        }

        // Face/navigation pinches often curl the remaining fingers. Do not
        // turn that incidental curl into a grab, even immediately on release.
        let pinch = active ?? candidate
        let blocksGrip = hasPulse || (pinch.map { $0 != .index } ?? false)
        if blocksGrip {
            gripNeedsRelax = true
            gripActive = false
            gripSince = nil
        } else if sample.gripCurl <= Self.gripUp {
            gripNeedsRelax = false
            gripActive = false
            gripSince = nil
        } else if !gripNeedsRelax, !gripActive {
            if sample.gripCurl >= Self.gripDown {
                if gripSince == nil { gripSince = time }
                if time - (gripSince ?? time) >= Self.debounce {
                    gripActive = true
                }
            } else {
                gripSince = nil
            }
        }
        output.grip = gripActive ? 1 : 0

        switch active {
        case .index:
            output.trigger = 1
        case .middle:
            let delta = sample.position - stickOrigin
            let metres = SIMD2<Float>(simd_dot(delta, stickRight),
                                      simd_dot(delta, stickForward))
            let distance = simd_length(metres)
            if distance > Self.stickDeadZone {
                let magnitude = min(1, (distance - Self.stickDeadZone)
                    / (Self.stickFullScale - Self.stickDeadZone))
                output.stick = metres / distance * magnitude
                middleStayedNeutral = false
            }
            if middleStayedNeutral, !holdDidFire,
               time - activeSince >= Self.longPress {
                stickClickPulseUntil = time + Self.pulseDuration
                holdDidFire = true
            }
        case .ring:
            output.primary = true
        case .little:
            if hand == 1 {
                output.secondary = true
            } else if !holdDidFire, time - activeSince >= Self.longPress {
                menuPulseUntil = time + Self.pulseDuration
                holdDidFire = true
            }
        case nil:
            break
        }
        output.secondary = output.secondary || time < secondaryPulseUntil
        output.menu = time < menuPulseUntil
        output.stickClick = time < stickClickPulseUntil
        return output
    }

    private static func valid(_ sample: KleptonGestureSample) -> Bool {
        guard Pinch.allCases.allSatisfy({
            let distance = $0.distance(in: sample)
            return distance.isFinite && (0...0.5).contains(distance)
        }), sample.gripCurl.isFinite, (0...1).contains(sample.gripCurl),
        finite(sample.position, limit: 1_000),
        finite(sample.stickRight, limit: 10),
        finite(sample.stickForward, limit: 10) else { return false }
        let right = SIMD3<Float>(sample.stickRight.x, 0, sample.stickRight.z)
        let forward = SIMD3<Float>(sample.stickForward.x, 0, sample.stickForward.z)
        guard simd_length_squared(right) > 0.0001,
              simd_length_squared(forward) > 0.0001 else { return false }
        // A near-vertical or degenerate basis cannot define horizontal input.
        return abs(simd_dot(simd_normalize(right), simd_normalize(forward))) < 0.98
    }

    private static func finite(_ vector: SIMD3<Float>, limit: Float) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
            && abs(vector.x) <= limit && abs(vector.y) <= limit
            && abs(vector.z) <= limit
    }

    private static func horizontalAxes(_ sample: KleptonGestureSample)
        -> (SIMD3<Float>, SIMD3<Float>) {
        let forward = simd_normalize(SIMD3<Float>(sample.stickForward.x, 0,
                                                 sample.stickForward.z))
        let right = SIMD3<Float>(sample.stickRight.x, 0, sample.stickRight.z)
        // Keep the supplied handedness while removing small basis skew.
        return (simd_normalize(right - forward * simd_dot(right, forward)), forward)
    }
}
