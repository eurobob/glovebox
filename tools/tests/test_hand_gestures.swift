import Foundation
import simd

@main
struct HandGestureTests {
    private static var checks = 0

    static func main() {
        startupAndDebounce()
        partialTracking()
        headingAvailability()
        quickIndexPress()
        naturalMiddleGeometry()
        adjacentFingerArbitration()
        exclusivityAndHysteresis()
        gripAndTrigger()
        navigationDoesNotGrab()
        trackingLossAndReacquisition()
        faceButtonsAndMenu()
        pulseCancellationAndExclusivity()
        virtualStick()
        stickClick()
        invalidInput()
        print("Hand gestures: \(checks) checks passed")
    }

    private static func sample(index: Float? = 0.08, middle: Float? = 0.08,
                               ring: Float? = 0.08, little: Float? = 0.08,
                               curl: Float? = 0, position: SIMD3<Float> = .zero,
                               right: SIMD3<Float> = SIMD3(1, 0, 0),
                               forward: SIMD3<Float> = SIMD3(0, 0, -1))
        -> KleptonGestureSample {
        KleptonGestureSample(indexPinch: index, middlePinch: middle,
                             ringPinch: ring, littlePinch: little,
                             gripCurl: curl, position: position,
                             stickRight: right, stickForward: forward)
    }

    private static func expect(_ condition: @autoclosure () -> Bool,
                               _ message: String, line: UInt = #line) {
        checks += 1
        guard condition() else {
            fatalError("Line \(line): \(message)")
        }
    }

    private static func neutral(_ output: KleptonGestureOutput) -> Bool {
        output.trigger == 0 && output.grip == 0 && output.stick == .zero
            && !output.primary && !output.secondary && !output.stickClick
            && !output.menu
    }

    private static func armed() -> KleptonHandGestures {
        var gestures = KleptonHandGestures()
        expect(neutral(gestures.update(sample: sample(), at: 0, hand: 0)),
               "Open hand arms without sending controls")
        return gestures
    }

    private static func startupAndDebounce() {
        var gestures = KleptonHandGestures()
        expect(neutral(gestures.update(sample: sample(index: 0.01), at: 0, hand: 0)),
               "Startup pinch does not fire")
        expect(neutral(gestures.update(sample: sample(index: 0.01), at: 1, hand: 0)),
               "Held startup pinch cannot arm")
        _ = gestures.update(sample: sample(), at: 2, hand: 0)
        expect(neutral(gestures.update(sample: sample(index: 0.02), at: 2.01, hand: 0)),
               "Pinch requires debounce")
        expect(neutral(gestures.update(sample: sample(index: 0.040), at: 2.025, hand: 0)),
               "Threshold jitter cancels candidate")
        _ = gestures.update(sample: sample(index: 0.02), at: 2.05, hand: 0)
        expect(neutral(gestures.update(sample: sample(index: 0.02), at: 2.065, hand: 0)),
               "Candidate must stay below down threshold")
        expect(gestures.update(sample: sample(index: 0.02), at: 2.08, hand: 0).trigger == 1,
               "Stable pinch fires")
    }

    private static func partialTracking() {
        var gestures = KleptonHandGestures()
        let indexOnlyOpen = sample(middle: nil, ring: nil, little: nil, curl: nil,
                                   right: .zero, forward: .zero)
        var indexOnlyPinch = indexOnlyOpen
        indexOnlyPinch.indexPinch = 0.038
        _ = gestures.update(sample: indexOnlyOpen, at: 0, hand: 0)
        _ = gestures.update(sample: indexOnlyPinch, at: 0.1, hand: 0)
        expect(gestures.update(sample: indexOnlyPinch, at: 0.122, hand: 0).trigger == 1,
               "Thumb/index alone can arm and select without other fingers, curl or heading")
        var occluded = sample(index: 0.038, little: nil, curl: nil)
        expect(gestures.update(sample: occluded, at: 0.14, hand: 0).trigger == 1,
               "Missing pinky or curl cannot reset an active index pinch")
        occluded.indexPinch = nil
        expect(neutral(gestures.update(sample: occluded, at: 0.15, hand: 0)),
               "Missing index immediately cancels even its minimum press pulse")
        expect(neutral(gestures.update(sample: indexOnlyPinch, at: 0.16, hand: 0)),
               "Reacquired closed index cannot restart fire")
        expect(neutral(gestures.update(sample: indexOnlyPinch, at: 1, hand: 0)),
               "Held reacquisition stays unarmed despite unrelated open fingers")
        _ = gestures.update(sample: indexOnlyOpen, at: 1.1, hand: 0)
        _ = gestures.update(sample: indexOnlyPinch, at: 1.2, hand: 0)
        expect(gestures.update(sample: indexOnlyPinch, at: 1.222, hand: 0).trigger == 1,
               "Only index needs an observed open sample to rearm index")

        var grip = KleptonHandGestures()
        _ = grip.update(sample: sample(curl: 0.95), at: 0, hand: 0)
        expect(grip.update(sample: sample(curl: 0.95), at: 0.1, hand: 0).grip == 0,
               "Initial closed fist must relax before grabbing")
        _ = grip.update(sample: sample(), at: 0.2, hand: 0)
        _ = grip.update(sample: sample(index: 0.038, curl: 0.95), at: 0.3, hand: 0)
        let both = grip.update(sample: sample(index: 0.038, curl: 0.95), at: 0.36, hand: 0)
        expect(both.grip == 1 && both.trigger == 1, "Rearmed grip combines with index")
        let lostCurl = grip.update(sample: sample(index: 0.038, curl: nil), at: 0.37, hand: 0)
        expect(lostCurl.grip == 0 && lostCurl.trigger == 1, "Lost curl releases grip only")
        expect(grip.update(sample: sample(index: 0.038, curl: 0.95), at: 0.5, hand: 0).grip == 0,
               "Grip reacquisition while curled cannot restart a grab")
        _ = grip.update(sample: sample(index: 0.038), at: 0.6, hand: 0)
        _ = grip.update(sample: sample(index: 0.038, curl: 0.95), at: 0.7, hand: 0)
        expect(grip.update(sample: sample(index: 0.038, curl: 0.95), at: 0.76, hand: 0).grip == 1,
               "Known relaxed curl rearms grip while index remains pressed")

        var left = armed()
        _ = left.update(sample: sample(little: 0.01), at: 0.1, hand: 0)
        _ = left.update(sample: sample(little: 0.01), at: 0.16, hand: 0)
        expect(neutral(left.update(sample: sample(little: nil), at: 0.2, hand: 0)),
               "Losing little finger cancels without synthesizing Y or menu")
        expect(neutral(left.update(sample: sample(little: 0.01), at: 1, hand: 0)),
               "Closed little-finger reacquisition does not start a long hold")
    }

    private static func headingAvailability() {
        var grip = armed()
        _ = grip.update(sample: sample(curl: 0.95, right: .zero, forward: .zero), at: 0.1, hand: 0)
        expect(grip.update(sample: sample(curl: 0.95, right: .zero, forward: .zero), at: 0.16, hand: 0).grip == 1,
               "Grip does not depend on a head heading")
        var face = armed()
        _ = face.update(sample: sample(ring: 0.01, right: .zero, forward: .zero), at: 0.1, hand: 0)
        expect(face.update(sample: sample(ring: 0.01, right: .zero, forward: .zero), at: 0.16, hand: 0).primary,
               "Face buttons do not depend on a head heading")
        var stick = armed()
        _ = stick.update(sample: sample(index: 0.038, middle: 0.01, right: .zero, forward: .zero), at: 0.1, hand: 0)
        expect(neutral(stick.update(sample: sample(index: 0.038, middle: 0.01, right: .zero, forward: .zero), at: 0.2, hand: 0)),
               "A middle clutch cannot start without heading or fall through into an accidental index press")
        _ = stick.update(sample: sample(middle: 0.01), at: 0.3, hand: 0)
        _ = stick.update(sample: sample(middle: 0.01), at: 0.36, hand: 0)
        let moving = stick.update(sample: sample(middle: 0.01, position: SIMD3(0.08, 0, 0),
                                                  right: .zero, forward: .zero), at: 0.4, hand: 0)
        expect(moving.stick.x > 0.99,
               "An active clutch uses its frozen heading through head unavailability")
        expect(neutral(stick.update(sample: sample(middle: nil), at: 0.41, hand: 0)),
               "Losing the middle channel immediately stops movement")
        expect(neutral(stick.update(sample: sample(middle: 0.01, position: SIMD3(1, 0, 0)), at: 0.5, hand: 0)),
               "Middle reacquisition while pinched cannot restart movement")
    }

    private static func quickIndexPress() {
        var gestures = armed()
        _ = gestures.update(sample: sample(index: 0.040), at: 0.1, hand: 0)
        expect(gestures.update(sample: sample(index: 0.040), at: 0.2, hand: 0).trigger == 0,
               "Index does not activate above its calibrated 39 mm threshold")
        _ = gestures.update(sample: sample(index: 0.039), at: 0.3, hand: 0)
        expect(gestures.update(sample: sample(index: 0.039), at: 0.322, hand: 0).trigger == 1,
               "39 mm index pinch activates after 20 ms")
        expect(gestures.update(sample: sample(index: 0.043), at: 0.39, hand: 0).trigger == 1,
               "Accepted index remains down inside the 44 mm release threshold")
        expect(gestures.update(sample: sample(index: 0.044), at: 0.4, hand: 0).trigger == 0,
               "44 mm releases an index held longer than the minimum press")

        _ = gestures.update(sample: sample(index: 0.038), at: 0.5, hand: 0)
        _ = gestures.update(sample: sample(index: 0.038), at: 0.522, hand: 0)
        expect(gestures.update(sample: sample(), at: 0.53, hand: 0).trigger == 1,
               "Quick physical release retains the accepted press for guest polling")
        expect(gestures.update(sample: sample(), at: 0.58, hand: 0).trigger == 1,
               "Accepted trigger pulse lasts at least 58 ms")
        expect(gestures.update(sample: sample(), at: 0.583, hand: 0).trigger == 0,
               "Minimum trigger pulse expires and cannot stick")
        _ = gestures.update(sample: sample(index: 0.038), at: 0.6, hand: 0)
        _ = gestures.update(sample: sample(index: 0.038), at: 0.622, hand: 0)
        expect(neutral(gestures.update(sample: nil, at: 0.63, hand: 0)),
               "Whole-hand tracking loss cancels a minimum pulse immediately")

        // Model a 45 ms physical pinch at 90 Hz, with every phase of a 45 Hz
        // guest poll. The former 50 ms debounce rejected this entire gesture.
        for phase in 0..<20 {
            var input = KleptonHandGestures()
            var guestTime = Double(phase) / 20 / 45
            var observed = false
            for frame in 0..<30 {
                let time = Double(frame) / 90
                let pinched = time >= 0.1 && time < 0.145
                let output = input.update(sample: sample(index: pinched ? 0.038 : 0.08), at: time, hand: 0)
                while guestTime < time + 1 / 90.0 {
                    if output.trigger == 1 { observed = true }
                    guestTime += 1 / 45.0
                }
            }
            expect(observed, "Quick index selection is visible at every tested 45 Hz polling phase")
        }
    }

    private static func naturalMiddleGeometry() {
        func geometry(thumb: SIMD3<Float>? = .zero, middle: SIMD3<Float>? = SIMD3(0.03, 0, 0),
                      ring: SIMD3<Float>? = SIMD3(0.04, -0.02, 0),
                      little: SIMD3<Float>? = SIMD3(0.04, -0.04, 0),
                      ringCurl: Float? = 0.9, littleCurl: Float? = 0.95,
                      position: SIMD3<Float> = .zero) -> KleptonGestureSample {
            // Index and middle tips are 15 mm apart; the middle joint remains
            // about 30 mm from the thumb at contact, like the index calibration.
            .fromFingertips(thumb: thumb, index: SIMD3(0.03, 0.015, 0), middle: middle,
                            ring: ring, little: little, middleCurl: 0.6,
                            ringCurl: ringCurl, littleCurl: littleCurl,
                            position: position, stickRight: SIMD3(1, 0, 0), stickForward: SIMD3(0, 0, -1))
        }
        let curled = geometry()
        expect(abs((curled.middlePinch ?? 1) - 0.03) < 0.00001,
               "Actual fingertip sampling keeps a middle pinch with naturally curled ring/little fingers")
        expect(curled.ringPinch == nil && curled.littlePinch == nil,
               "The existing conservative face-button gates remain unchanged")
        let occluded = geometry(ring: nil, little: nil, ringCurl: nil, littleCurl: nil)
        expect(abs((occluded.middlePinch ?? 1) - 0.03) < 0.00001 && occluded.gripCurl == nil,
               "Missing unrelated fingertip/curl measurements cannot erase navigation")
        expect(geometry(thumb: nil).middlePinch == nil, "Navigation still needs a tracked thumb")
        expect(geometry(middle: nil).middlePinch == nil, "Navigation still needs its own tracked fingertip")

        var gestures = KleptonHandGestures()
        _ = gestures.update(sample: geometry(thumb: SIMD3(-0.08, 0, 0)), at: 0, hand: 0)
        // At 34 mm the old 23 mm middle threshold excluded navigation while
        // the adjacent index (37 mm away) could already fire. The actual
        // geometric lead now makes middle the sole eligible target.
        expect(neutral(gestures.update(sample: geometry(thumb: SIMD3(-0.004, 0, 0)), at: 0.1, hand: 0)),
               "A natural middle approach starts debounce without firing index")
        expect(neutral(gestures.update(sample: geometry(thumb: SIMD3(-0.001, 0, 0)), at: 0.122, hand: 0)),
               "Middle activates at 31 mm using the same delay as index")
        var output = gestures.update(sample: geometry(thumb: SIMD3(-0.001, 0, 0),
                                                        position: SIMD3(0.06, 0, 0)), at: 0.15, hand: 0)
        expect(output.stick.x > 0.7 && output.trigger == 0 && output.grip == 0,
               "Natural folded-neighbour pinch drives navigation without trigger or grab")
        output = gestures.update(sample: geometry(thumb: SIMD3(-0.001, 0, 0), ring: nil, little: nil,
                                                   ringCurl: nil, littleCurl: nil,
                                                   position: SIMD3(0.06, 0, 0)), at: 0.16, hand: 0)
        expect(output.stick.x > 0.7 && output.trigger == 0,
               "Navigation continues when unrelated fingers become occluded")
        expect(neutral(gestures.update(sample: geometry(middle: nil), at: 0.17, hand: 0)),
               "Own fingertip loss immediately stops navigation")
        expect(neutral(gestures.update(sample: geometry(middle: nil), at: 0.2, hand: 0)),
               "The adjacent closed index cannot take over after middle tracking loss")
        expect(neutral(gestures.update(sample: geometry(middle: nil), at: 0.25, hand: 0)),
               "A lost navigation pinch cannot become fire after the index debounce delay")
        expect(neutral(gestures.update(sample: geometry(), at: 0.3, hand: 0)),
               "Reappearing closed middle still requires a new observed-open sample")
    }

    private static func adjacentFingerArbitration() {
        var gestures = armed()
        for frame in 0..<10 {
            let index: Float = frame % 2 == 0 ? 0.030 : 0.031
            let middle: Float = frame % 2 == 0 ? 0.031 : 0.030
            expect(neutral(gestures.update(sample: sample(index: index, middle: middle),
                                           at: 0.1 + Double(frame) * 0.025, hand: 0)),
                   "Ambiguous neighbouring fingertips cannot flicker into index or navigation")
        }
        _ = gestures.update(sample: sample(index: 0.038, middle: 0.030), at: 0.4, hand: 0)
        _ = gestures.update(sample: sample(index: 0.038, middle: 0.030), at: 0.422, hand: 0)
        let moving = gestures.update(sample: sample(index: 0.038, middle: 0.030,
                                                     position: SIMD3(0.08, 0, 0)), at: 0.45, hand: 0)
        expect(moving.stick.x > 0.99 && moving.trigger == 0,
               "A clear middle lead resolves ambiguity without an earlier trigger press")

        var face = armed()
        _ = face.update(sample: sample(index: 0.035, ring: 0.026), at: 0.1, hand: 0)
        expect(neutral(face.update(sample: sample(index: 0.035, ring: 0.026), at: 0.13, hand: 0)),
               "A closer ring just outside its own threshold prevents a farther index from firing")
        _ = face.update(sample: sample(index: 0.035, ring: 0.018), at: 0.2, hand: 0)
        let pressed = face.update(sample: sample(index: 0.035, ring: 0.018), at: 0.26, hand: 0)
        expect(pressed.primary && pressed.trigger == 0, "Ring button still activates at its existing threshold")

        var unarmed = KleptonHandGestures()
        _ = unarmed.update(sample: sample(middle: 0.02), at: 0, hand: 0)
        _ = unarmed.update(sample: sample(index: 0.036, middle: 0.025), at: 0.1, hand: 0)
        expect(neutral(unarmed.update(sample: sample(index: 0.036, middle: 0.025), at: 0.13, hand: 0)),
               "A closer unarmed fingertip cannot be ignored in favour of an accidental trigger")
    }

    private static func exclusivityAndHysteresis() {
        var gestures = armed()
        let ambiguous = sample(index: 0.019, middle: 0.01, ring: 0.018, little: 0.021)
        _ = gestures.update(sample: ambiguous, at: 0.1, hand: 0)
        var output = gestures.update(sample: ambiguous, at: 0.16, hand: 0)
        expect(neutral(output), "Closest middle pinch owns controls at its origin")
        output = gestures.update(sample: sample(index: 0.005, middle: 0.028,
                                                ring: 0.004, little: 0.003,
                                                position: SIMD3(0.08, 0, 0)),
                                 at: 0.2, hand: 0)
        expect(output.stick.x > 0.99 && output.trigger == 0 && !output.primary
                && !output.secondary, "Active middle pinch cannot be stolen")
        output = gestures.update(sample: sample(index: 0.005, middle: 0.045), at: 0.3, hand: 0)
        expect(neutral(output), "Release clears stick without switching immediately")
        _ = gestures.update(sample: sample(index: 0.02), at: 0.4, hand: 0)
        _ = gestures.update(sample: sample(index: 0.02), at: 0.46, hand: 0)
        expect(gestures.update(sample: sample(index: 0.031), at: 0.5, hand: 0).trigger == 1,
               "Pinch stays down between hysteresis thresholds")
        expect(neutral(gestures.update(sample: sample(index: 0.045), at: 0.6, hand: 0)),
               "Open threshold releases trigger")
    }

    private static func gripAndTrigger() {
        var gestures = armed()
        let both = sample(index: 0.01, curl: 0.9)
        _ = gestures.update(sample: both, at: 0.1, hand: 0)
        var output = gestures.update(sample: both, at: 0.16, hand: 0)
        expect(output.trigger == 1 && output.grip == 1, "Deliberate grip and trigger coexist")
        output = gestures.update(sample: sample(index: 0.028, curl: 0.65), at: 0.2, hand: 0)
        expect(output.trigger == 1 && output.grip == 1, "Grip has independent hysteresis")
        output = gestures.update(sample: sample(index: 0.028, curl: 0.5), at: 0.3, hand: 0)
        expect(output.trigger == 1 && output.grip == 0, "Relaxing grip leaves trigger held")
    }

    private static func navigationDoesNotGrab() {
        for finger in 0..<3 {
            var gestures = armed()
            let pinch = sample(middle: finger == 0 ? 0.01 : 0.08,
                               ring: finger == 1 ? 0.01 : 0.08,
                               little: finger == 2 ? 0.01 : 0.08, curl: 0.95)
            expect(gestures.update(sample: pinch, at: 0.1, hand: 0).grip == 0,
                   "Non-trigger pinch blocks grip during debounce")
            expect(gestures.update(sample: pinch, at: 0.16, hand: 0).grip == 0,
                   "Non-trigger pinch never grabs")
            _ = gestures.update(sample: sample(curl: 0.95), at: 0.2, hand: 0)
            expect(gestures.update(sample: sample(curl: 0.95), at: 0.4, hand: 0).grip == 0,
                   "Incidental curl does not grab after pinch release")
            _ = gestures.update(sample: sample(), at: 0.5, hand: 0)
            _ = gestures.update(sample: sample(curl: 0.95), at: 0.6, hand: 0)
            expect(gestures.update(sample: sample(curl: 0.95), at: 0.66, hand: 0).grip == 1,
                   "Relaxing re-enables deliberate grip")
        }
    }

    private static func trackingLossAndReacquisition() {
        var gestures = armed()
        _ = gestures.update(sample: sample(index: 0.01, curl: 0.9), at: 0.1, hand: 0)
        _ = gestures.update(sample: sample(index: 0.01, curl: 0.9), at: 0.16, hand: 0)
        expect(neutral(gestures.update(sample: nil, at: 0.17, hand: 0)),
               "Tracking loss releases fire and grip immediately")
        expect(neutral(gestures.update(sample: sample(index: 0.01), at: 0.2, hand: 0)),
               "Reacquired pinch cannot fire")
        expect(neutral(gestures.update(sample: sample(index: 0.01), at: 1, hand: 0)),
               "Reacquired held pinch remains blocked")
        _ = gestures.update(sample: sample(), at: 1.1, hand: 0)
        _ = gestures.update(sample: sample(middle: 0.01), at: 1.2, hand: 0)
        _ = gestures.update(sample: sample(middle: 0.01), at: 1.26, hand: 0)
        expect(gestures.update(sample: sample(middle: 0.01, position: SIMD3(0.08, 0, 0)),
                               at: 1.3, hand: 0).stick.x > 0.99, "Armed clutch moves")
        expect(neutral(gestures.update(sample: nil, at: 1.31, hand: 0)),
               "Tracking loss stops movement immediately")
        _ = gestures.update(sample: sample(position: SIMD3(1, 0, 0)), at: 1.4, hand: 0)
        _ = gestures.update(sample: sample(middle: 0.01, position: SIMD3(1, 0, 0)), at: 1.5, hand: 0)
        expect(gestures.update(sample: sample(middle: 0.01, position: SIMD3(1, 0, 0)),
                               at: 1.56, hand: 0).stick == .zero,
               "Reacquisition discards old stick origin")
    }

    private static func faceButtonsAndMenu() {
        var gestures = armed()
        _ = gestures.update(sample: sample(ring: 0.01), at: 0.1, hand: 0)
        expect(gestures.update(sample: sample(ring: 0.01), at: 0.16, hand: 0).primary,
               "Ring pinch holds primary")
        expect(neutral(gestures.update(sample: sample(), at: 0.2, hand: 0)),
               "Ring release clears primary")
        _ = gestures.update(sample: sample(little: 0.01), at: 0.3, hand: 0)
        expect(neutral(gestures.update(sample: sample(little: 0.01), at: 0.36, hand: 0)),
               "Left little does not send secondary prematurely")
        var output = gestures.update(sample: sample(), at: 0.4, hand: 0)
        expect(output.secondary && !output.menu, "Left short tap emits secondary on release")
        expect(gestures.update(sample: sample(), at: 0.51, hand: 0).secondary,
               "Short-tap pulse survives slower input polling")
        expect(neutral(gestures.update(sample: sample(), at: 0.53, hand: 0)),
               "Short-tap pulse expires after 120 ms")
        _ = gestures.update(sample: sample(little: 0.01), at: 0.6, hand: 0)
        _ = gestures.update(sample: sample(little: 0.01), at: 0.66, hand: 0)
        output = gestures.update(sample: sample(little: 0.01), at: 1.41, hand: 0)
        expect(output.menu && !output.secondary, "Left long hold emits only menu")
        expect(gestures.update(sample: sample(little: 0.01), at: 1.52, hand: 0).menu,
               "Menu pulse lasts at least 110 ms")
        expect(neutral(gestures.update(sample: sample(little: 0.01), at: 1.54, hand: 0)),
               "Menu pulse expires without repeating during hold")
        expect(neutral(gestures.update(sample: sample(little: 0.01), at: 3, hand: 0)),
               "Continued hold never repeats menu")
        expect(neutral(gestures.update(sample: sample(), at: 3.1, hand: 0)),
               "Long-hold release does not emit secondary")
        _ = gestures.update(sample: sample(little: 0.01), at: 3.2, hand: 0)
        _ = gestures.update(sample: sample(little: 0.01), at: 3.26, hand: 0)
        output = gestures.update(sample: sample(), at: 4.01, hand: 0)
        expect(output.menu && !output.secondary, "Release crossing long boundary still emits menu")

        var right = KleptonHandGestures()
        _ = right.update(sample: sample(), at: 0, hand: 1)
        _ = right.update(sample: sample(little: 0.01), at: 0.1, hand: 1)
        expect(right.update(sample: sample(little: 0.01), at: 0.16, hand: 1).secondary,
               "Right little holds secondary after debounce")
        output = right.update(sample: sample(little: 0.01), at: 1, hand: 1)
        expect(output.secondary && !output.menu, "Right long hold remains secondary")
    }

    private static func pulseCancellationAndExclusivity() {
        for gesture in 0..<3 {
            var gestures = armed()
            let pinch = sample(middle: gesture == 2 ? 0.01 : 0.08,
                               little: gesture == 2 ? 0.08 : 0.01)
            _ = gestures.update(sample: pinch, at: 0.1, hand: 0)
            _ = gestures.update(sample: pinch, at: 0.16, hand: 0)
            let output = gestures.update(sample: gesture == 0 ? sample() : pinch,
                                         at: 0.91, hand: 0)
            // Gesture 0 needs a short release, so use a separate sequence below
            // for Y; these two held cases cover menu and stick-click loss.
            if gesture > 0 {
                expect(gesture == 1 ? output.menu : output.stickClick,
                       "Long hold emits the intended pulse")
            }
            expect(neutral(gestures.update(sample: nil, at: 0.92, hand: 0)),
                   "Tracking loss cancels an in-flight pulse immediately")
            expect(neutral(gestures.update(sample: pinch, at: 0.93, hand: 0)),
                   "Held reacquisition cannot restart a pulse")
            _ = gestures.update(sample: sample(), at: 1.0, hand: 0)
            expect(neutral(gestures.update(sample: sample(), at: 1.01, hand: 0)),
                   "Cancelled pulse does not return after rearming")
        }

        var gestures = armed()
        _ = gestures.update(sample: sample(little: 0.01), at: 0.1, hand: 0)
        _ = gestures.update(sample: sample(little: 0.01), at: 0.16, hand: 0)
        expect(gestures.update(sample: sample(), at: 0.2, hand: 0).secondary,
               "Short release starts Y pulse")
        _ = gestures.update(sample: sample(ring: 0.01), at: 0.21, hand: 0)
        let overlap = gestures.update(sample: sample(ring: 0.01), at: 0.27, hand: 0)
        expect(overlap.secondary && !overlap.primary,
               "New pinch cannot overlap the old pulse")
        expect(neutral(gestures.update(sample: nil, at: 0.28, hand: 0)),
               "Tracking loss cancels Y pulse immediately")
    }

    private static func virtualStick() {
        var gestures = armed()
        let origin = SIMD3<Float>(2, 1, 3)
        _ = gestures.update(sample: sample(middle: 0.01, position: origin), at: 0.1, hand: 0)
        _ = gestures.update(sample: sample(middle: 0.01, position: origin), at: 0.16, hand: 0)
        var output = gestures.update(sample: sample(middle: 0.01, position: origin + SIMD3(0.009, 1, 0)),
                                     at: 0.2, hand: 0)
        expect(output.stick == .zero, "One-centimetre dead zone ignores vertical motion")
        output = gestures.update(sample: sample(middle: 0.01, position: origin + SIMD3(0.045, 0, 0)),
                                 at: 0.3, hand: 0)
        expect(abs(output.stick.x - 0.5) < 0.001 && abs(output.stick.y) < 0.001,
               "Stick scales linearly outside dead zone")
        output = gestures.update(sample: sample(middle: 0.01, position: origin + SIMD3(0.08, 0, -0.08),
                                                right: SIMD3(0, 0, 1), forward: SIMD3(1, 0, 0)),
                                 at: 0.4, hand: 0)
        expect(abs(simd_length(output.stick) - 1) < 0.001
                && output.stick.x > 0.7 && output.stick.y > 0.7,
               "Clutch freezes axes and radially caps diagonal input")
        expect(neutral(gestures.update(sample: sample(), at: 0.5, hand: 0)),
               "Opening clutch immediately stops stick")
        _ = gestures.update(sample: sample(middle: 0.01, right: SIMD3(0, 0, 1),
                                           forward: SIMD3(1, 0.5, 0)), at: 0.6, hand: 0)
        _ = gestures.update(sample: sample(middle: 0.01, right: SIMD3(0, 0, 1),
                                           forward: SIMD3(1, 0.5, 0)), at: 0.66, hand: 0)
        output = gestures.update(sample: sample(middle: 0.01, position: SIMD3(0.08, 1, 0)),
                                 at: 0.7, hand: 0)
        expect(abs(output.stick.x) < 0.001 && output.stick.y > 0.99,
               "New clutch captures new flattened camera axes")
    }

    private static func stickClick() {
        var gestures = armed()
        _ = gestures.update(sample: sample(middle: 0.01), at: 0.1, hand: 0)
        _ = gestures.update(sample: sample(middle: 0.01), at: 0.16, hand: 0)
        expect(gestures.update(sample: sample(middle: 0.01), at: 0.91, hand: 0).stickClick,
               "Stationary clutch hold emits stick click")
        expect(gestures.update(sample: sample(middle: 0.01), at: 1.02, hand: 0).stickClick,
               "Stick-click pulse lasts at least 110 ms")
        expect(!gestures.update(sample: sample(middle: 0.01), at: 1.04, hand: 0).stickClick,
               "Stick-click pulse expires without repeating")
        _ = gestures.update(sample: sample(), at: 1.1, hand: 0)
        _ = gestures.update(sample: sample(middle: 0.01), at: 1.2, hand: 0)
        _ = gestures.update(sample: sample(middle: 0.01), at: 1.26, hand: 0)
        _ = gestures.update(sample: sample(middle: 0.01, position: SIMD3(0.02, 0, 0)), at: 1.3, hand: 0)
        expect(!gestures.update(sample: sample(middle: 0.01), at: 2.1, hand: 0).stickClick,
               "Moving clutch cancels click even after returning to neutral")
    }

    private static func invalidInput() {
        let badSamples = [sample(index: Float.nan), sample(index: -0.01), sample(index: 0.6),
                          sample(position: SIMD3(.infinity, 0, 0)),
                          sample(position: SIMD3(1_001, 0, 0))]
        for bad in badSamples {
            var gestures = armed()
            _ = gestures.update(sample: sample(index: 0.01), at: 0.1, hand: 0)
            _ = gestures.update(sample: sample(index: 0.01), at: 0.16, hand: 0)
            expect(neutral(gestures.update(sample: bad, at: 0.2, hand: 0)),
                   "Invalid index or whole pose immediately clears trigger")
            expect(neutral(gestures.update(sample: sample(index: 0.01), at: 0.3, hand: 0)),
                   "Invalid index or pose requires index neutral reacquisition")
        }
        let unrelated = [sample(index: 0.038, ring: 0.6), sample(index: 0.038, curl: Float.infinity),
                         sample(index: 0.038, curl: 1.1), sample(index: 0.038, right: .zero),
                         sample(index: 0.038, forward: SIMD3(0, 1, 0)),
                         sample(index: 0.038, forward: SIMD3(1, 0, 0)),
                         sample(index: 0.038, right: SIMD3(.nan, 0, 0))]
        for degraded in unrelated {
            var gestures = armed()
            _ = gestures.update(sample: sample(index: 0.038), at: 0.1, hand: 0)
            _ = gestures.update(sample: sample(index: 0.038), at: 0.122, hand: 0)
            expect(gestures.update(sample: degraded, at: 0.2, hand: 0).trigger == 1,
                   "Invalid unrelated channel or heading cannot cancel a valid trigger")
        }
        var gestures = armed()
        expect(neutral(gestures.update(sample: sample(), at: .nan, hand: 0)), "NaN time resets")
        _ = gestures.update(sample: sample(), at: 1, hand: 0)
        expect(neutral(gestures.update(sample: sample(index: 0.01), at: 0.5, hand: 0)),
               "Backwards time resets")
        _ = gestures.update(sample: sample(), at: 1, hand: 0)
        expect(neutral(gestures.update(sample: sample(index: 0.01), at: 2, hand: 2)),
               "Invalid hand resets")
    }
}
