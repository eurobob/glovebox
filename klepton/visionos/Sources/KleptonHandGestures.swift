// Pure hand-input interpretation. Kept independent of ARKit and OVR so the
// noisy-input and tracking-loss rules can be tested on the Mac.
import Foundation
import simd

struct KleptonGestureSample {
    // Thumb-to-fingertip distances, in metres. Nil means that channel is
    // unavailable, not that the finger is open.
    var indexPinch: Float?
    var middlePinch: Float?
    var ringPinch: Float?
    var littlePinch: Float?
    // Curl supported by at least two fingers: open = 0, fist = 1.
    var gripCurl: Float?
    var position: SIMD3<Float>
    // Head-relative world-space axes. The clutch freezes these at activation.
    var stickRight: SIMD3<Float>
    var stickForward: SIMD3<Float>

    /// Shared by ARKit and the pure geometry tests. Index selection and middle
    /// navigation need only their own fingertip and the thumb. A naturally
    /// folded or occluded ring/little finger must not erase a middle pinch.
    static func fromFingertips(thumb: SIMD3<Float>?, index: SIMD3<Float>?,
                              middle: SIMD3<Float>?, ring: SIMD3<Float>?, little: SIMD3<Float>?,
                              middleCurl: Float?, ringCurl: Float?, littleCurl: Float?,
                              position: SIMD3<Float>, stickRight: SIMD3<Float>,
                              stickForward: SIMD3<Float>) -> Self {
        func distance(to tip: SIMD3<Float>?) -> Float? {
            guard let thumb, let tip else { return nil }
            let distance = simd_distance(thumb, tip)
            return distance.isFinite ? distance : nil
        }
        func faceDistance(to tip: SIMD3<Float>?, others: (Float?, Float?)) -> Float? {
            // Retain the existing conservative face-button/fist distinction.
            guard let a = others.0, let b = others.1, a < 0.5, b < 0.5 else { return nil }
            return distance(to: tip)
        }
        // Fist tips often occlude one another. Two tracked curled fingers are
        // enough evidence; one finger alone cannot start or sustain a grab.
        let curls = [middleCurl, ringCurl, littleCurl].compactMap { value -> Float? in
            guard let value, value.isFinite, (0...1).contains(value) else { return nil }
            return value
        }.sorted(by: >)
        let grip = curls.count >= 2 ? curls[1] : nil
        return Self(indexPinch: distance(to: index), middlePinch: distance(to: middle),
                    ringPinch: faceDistance(to: ring, others: (middleCurl, littleCurl)),
                    littlePinch: faceDistance(to: little, others: (middleCurl, ringCurl)),
                    gripCurl: grip, position: position,
                    stickRight: stickRight, stickForward: stickForward)
    }
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
/// Pinch hysteresis avoids flickering fire around an analog press threshold;
/// an accepted index press lasts at least 60 ms. Brief individual-joint loss
/// can retain an accepted trigger/grip; whole-hand loss always releases both.
struct KleptonHandGestures {
    private enum Pinch: CaseIterable, Hashable {
        case index, middle, ring, little

        func distance(in sample: KleptonGestureSample) -> Float? {
            switch self {
            case .index: return sample.indexPinch
            case .middle: return sample.middlePinch
            case .ring: return sample.ringPinch
            case .little: return sample.littlePinch
            }
        }

        // Index preserves the device-tested legacy calibration. Middle uses
        // the same range and delay so index cannot win merely by qualifying
        // earlier as the thumb approaches the adjacent middle fingertip.
        var down: Float { self == .index || self == .middle ? 0.039 : 0.023 }
        var up: Float { self == .index || self == .middle ? 0.044 : 0.032 }
        var debounce: Double { self == .index || self == .middle ? 0.02 : 0.05 }
    }

    private static let gripDown: Float = 0.80
    private static let gripUp: Float = 0.55
    private static let debounce: Double = 0.05
    private static let longPress: Double = 0.8
    private static let pulseDuration: Double = 0.12
    private static let minimumTriggerPress: Double = 0.06
    private static let indexOcclusionGrace: Double = 0.06
    private static let gripOcclusionGrace: Double = 0.12
    private static let stickDeadZone: Float = 0.01
    private static let stickFullScale: Float = 0.08
    private static let pinchLead: Float = 0.003

    private var armedPinches = Set<Pinch>()
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
    private var gripNeedsRelax = true
    private var lastIndexTrackedAt: Double?
    private var lastGripTrackedAt: Double?
    private var triggerPulseUntil: Double = 0
    private var secondaryPulseUntil: Double = 0
    private var menuPulseUntil: Double = 0
    private var stickClickPulseUntil: Double = 0

    mutating func update(sample: KleptonGestureSample?, at time: Double,
                         hand: Int) -> KleptonGestureOutput {
        guard var sample, Self.finite(sample.position, limit: 1_000), time.isFinite, time >= 0,
              hand == 0 || hand == 1,
              lastTime.map({ time >= $0 }) ?? true,
              lastHand.map({ hand == $0 }) ?? true else {
            self = Self()
            return .neutral
        }
        lastTime = time
        lastHand = hand

        // A missing/invalid joint only invalidates its own control. In
        // particular, selecting with thumb/index never needs ring/little curl.
        let indexUnknown = sample.indexPinch == nil
        let gripUnknown = sample.gripCurl == nil
        sample.indexPinch = Self.validScalar(sample.indexPinch, range: 0...0.5)
        sample.middlePinch = Self.validScalar(sample.middlePinch, range: 0...0.5)
        sample.ringPinch = Self.validScalar(sample.ringPinch, range: 0...0.5)
        sample.littlePinch = Self.validScalar(sample.littlePinch, range: 0...0.5)
        sample.gripCurl = Self.validScalar(sample.gripCurl, range: 0...1)
        if sample.indexPinch != nil { lastIndexTrackedAt = time }
        if sample.gripCurl != nil { lastGripTrackedAt = time }
        let retainUnknownGrip = gripActive && gripUnknown
            && lastGripTrackedAt.map { time - $0 <= Self.gripOcclusionGrace } == true
        let protectGrip = gripActive && (retainUnknownGrip
            || sample.gripCurl.map { $0 > Self.gripUp } == true)
        let headingValid = Self.validHeading(sample)

        var output = KleptonGestureOutput.neutral
        var released = false
        for pinch in Pinch.allCases {
            guard let distance = pinch.distance(in: sample) else {
                // Contact itself can hide the index/thumbnail for a frame.
                // Only an already accepted press gets this bounded grace;
                // unknown tracking can never start or extend a new press.
                if pinch == .index, indexUnknown,
                   active == .index || time < triggerPulseUntil,
                   lastIndexTrackedAt.map({ time - $0 <= Self.indexOcclusionGrace }) == true {
                    continue
                }
                armedPinches.remove(pinch)
                if candidate == pinch { candidate = nil }
                if active == pinch {
                    // A neighbour already near the thumb is not a new pinch.
                    // Losing navigation must not make that adjacent index tip
                    // take over as fire on the following frame.
                    for other in Pinch.allCases where other != pinch {
                        if let distance = other.distance(in: sample), distance < other.up {
                            armedPinches.remove(other)
                        }
                    }
                    clearActive()
                    released = true
                }
                // Loss is a cancellation, never a synthetic tap release.
                switch pinch {
                case .index: triggerPulseUntil = 0
                case .middle: stickClickPulseUntil = 0
                case .little: secondaryPulseUntil = 0; menuPulseUntil = 0
                case .ring: break
                }
                continue
            }
            // Each channel must independently see a tracked open sample after
            // startup/loss. An unrelated occlusion never unarms this channel.
            if distance >= pinch.up { armedPinches.insert(pinch) }
            // A held object's curled fingers may brush the thumb. They must
            // open again before being interpreted as navigation/face input.
            if gripActive, pinch != .index, distance < pinch.up {
                armedPinches.remove(pinch)
            }
        }
        if let active, let distance = active.distance(in: sample), distance >= active.up {
            if active == .little, hand == 0, !holdDidFire {
                // Also classify correctly if the release frame crosses the
                // long-press boundary without an intervening held frame.
                if time - activeSince >= Self.longPress {
                    menuPulseUntil = time + Self.pulseDuration
                } else {
                    secondaryPulseUntil = time + Self.pulseDuration
                }
            }
            clearActive()
            released = true
        }

        let hasOtherPulse = time < secondaryPulseUntil || time < menuPulseUntil
            || time < stickClickPulseUntil
        let hasPulse = hasOtherPulse || time < triggerPulseUntil
        // Finishing a momentary press precedes recognizing the next pinch, so
        // changing fingers quickly cannot overlap two exclusive button presses.
        if active == nil, !released, !hasPulse {
            // Compare all observed distances before applying press thresholds.
            // A fingertip just outside its own threshold must still prevent a
            // farther index fingertip from claiming the gesture. Near ties are
            // ambiguous rather than automatic index presses. Once latched, the
            // chosen finger keeps ownership until release/tracking loss.
            let observed = Pinch.allCases.compactMap { pinch -> (Pinch, Float)? in
                guard let distance = pinch.distance(in: sample) else { return nil }
                return (pinch, distance)
            }
            let closest = observed.min { $0.1 < $1.1 }
            let nearest: Pinch?
            if let (pinch, distance) = closest,
               armedPinches.contains(pinch), distance <= pinch.down,
               !protectGrip || pinch == .index,
               observed.allSatisfy({ $0.0 == pinch || $0.1 - distance >= Self.pinchLead }) {
                nearest = pinch
            } else {
                nearest = nil
            }
            if nearest != candidate {
                candidate = nearest
                candidateSince = time
            }
            // A clearly closer middle pinch still owns the classification if
            // heading is absent; it must not become an accidental index press.
            if candidate == .middle, !headingValid { candidateSince = time }
            if let candidate, time - candidateSince >= candidate.debounce,
               candidate != .middle || headingValid {
                active = candidate
                activeSince = candidateSince
                holdDidFire = false
                middleStayedNeutral = true
                if candidate == .middle {
                    stickOrigin = sample.position
                    (stickRight, stickForward) = Self.horizontalAxes(sample)
                }
                if candidate == .index {
                    // A 45 Hz guest must observe an accepted quick selection.
                    // Whole-hand loss cancels this floor immediately.
                    triggerPulseUntil = time + Self.minimumTriggerPress
                }
                self.candidate = nil
            }
        }

        // Face/navigation pinches often curl the remaining fingers. Do not
        // turn that incidental curl into a grab, even immediately on release.
        let pinch = active ?? candidate
        let blocksGrip = hasOtherPulse || (pinch.map { $0 != .index } ?? false)
        if blocksGrip || (sample.gripCurl == nil && !retainUnknownGrip) {
            gripNeedsRelax = true
            gripActive = false
            gripSince = nil
        } else if let curl = sample.gripCurl, curl <= Self.gripUp {
            gripNeedsRelax = false
            gripActive = false
            gripSince = nil
        } else if let curl = sample.gripCurl, !gripNeedsRelax, !gripActive {
            if curl >= Self.gripDown {
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
        if time < triggerPulseUntil { output.trigger = 1 }
        output.secondary = output.secondary || time < secondaryPulseUntil
        output.menu = time < menuPulseUntil
        output.stickClick = time < stickClickPulseUntil
        return output
    }

    private mutating func clearActive() {
        active = nil
        candidate = nil
        holdDidFire = false
        middleStayedNeutral = true
        stickOrigin = .zero
        stickRight = .zero
        stickForward = .zero
    }

    private static func validScalar(_ value: Float?, range: ClosedRange<Float>) -> Float? {
        guard let value, value.isFinite, range.contains(value) else { return nil }
        return value
    }

    private static func validHeading(_ sample: KleptonGestureSample) -> Bool {
        guard finite(sample.stickRight, limit: 10),
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
