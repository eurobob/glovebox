import Foundation
import simd

@main
struct HandGestureTests {
    private static var checks = 0

    static func main() {
        startupAndDebounce()
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

    private static func sample(index: Float = 0.08, middle: Float = 0.08,
                               ring: Float = 0.08, little: Float = 0.08,
                               curl: Float = 0, position: SIMD3<Float> = .zero,
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
        expect(neutral(gestures.update(sample: sample(index: 0.024), at: 2.04, hand: 0)),
               "Threshold jitter cancels candidate")
        _ = gestures.update(sample: sample(index: 0.02), at: 2.05, hand: 0)
        expect(neutral(gestures.update(sample: sample(index: 0.02), at: 2.09, hand: 0)),
               "Candidate must stay below down threshold")
        expect(gestures.update(sample: sample(index: 0.02), at: 2.11, hand: 0).trigger == 1,
               "Stable pinch fires")
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
        output = gestures.update(sample: sample(index: 0.005, middle: 0.033), at: 0.3, hand: 0)
        expect(neutral(output), "Release clears stick without switching immediately")
        _ = gestures.update(sample: sample(index: 0.02), at: 0.4, hand: 0)
        _ = gestures.update(sample: sample(index: 0.02), at: 0.46, hand: 0)
        expect(gestures.update(sample: sample(index: 0.031), at: 0.5, hand: 0).trigger == 1,
               "Pinch stays down between hysteresis thresholds")
        expect(neutral(gestures.update(sample: sample(index: 0.033), at: 0.6, hand: 0)),
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
        var badSamples = [sample(index: .nan), sample(index: -0.01), sample(ring: 0.6),
                          sample(curl: .infinity), sample(curl: 1.1),
                          sample(position: SIMD3(.infinity, 0, 0)),
                          sample(position: SIMD3(1_001, 0, 0)), sample(right: .zero),
                          sample(forward: SIMD3(0, 1, 0)), sample(forward: SIMD3(1, 0, 0))]
        badSamples.append(sample(right: SIMD3(.nan, 0, 0)))
        for bad in badSamples {
            var gestures = armed()
            _ = gestures.update(sample: sample(index: 0.01), at: 0.1, hand: 0)
            _ = gestures.update(sample: sample(index: 0.01), at: 0.16, hand: 0)
            expect(neutral(gestures.update(sample: bad, at: 0.2, hand: 0)),
                   "Invalid sample immediately clears all controls")
            expect(neutral(gestures.update(sample: sample(index: 0.01), at: 0.3, hand: 0)),
                   "Invalid sample requires neutral reacquisition")
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
