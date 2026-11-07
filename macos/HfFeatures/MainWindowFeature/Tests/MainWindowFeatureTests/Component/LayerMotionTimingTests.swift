import Foundation
@testable import MainWindowFeature
import SwiftUI
import Testing

/// The pure timing of the feed's layer indicators: the phase lock and the caret curve.
@Suite struct LayerMotionTimingTests {
    @Test func givenFixedInputs_whenBeginTimeIsDerived_thenLocalTimeEqualsReferenceDatePhase() {
        // given
        let cases: [(layer: Double, reference: Double, period: Double)] = [
            (100, 1000.3, 1.2), (5.5, 0, 1.2), (12345.678, 800_000_000.25, 1.0), (0.01, 1.2 * 7 + 0.0001, 1.2), (9, 123.456, 1.6)
        ]
        for input in cases {
            // when
            let begin = LayerMotion.beginTime(layerTime: input.layer, referenceDate: input.reference, period: input.period)
            // then: an animation begun at `begin` is at local time `layer - begin` when the layer clock reads `layer`.
            let local = input.layer - begin
            #expect(abs(local - input.reference.truncatingRemainder(dividingBy: input.period)) < 1e-9)
            #expect(local >= 0 && local < input.period)
        }
    }

    @Test func givenKnownPhase_whenBeginTimeIsDerived_thenValueMatchesHandComputation() {
        // given 1000.3 mod 1.2 = 0.7 (833 whole periods)
        // when
        let begin = LayerMotion.beginTime(layerTime: 100, referenceDate: 1000.3, period: 1.2)
        // then
        #expect(abs(begin - 99.3) < 1e-9)
    }

    @Test func givenExactMultiple_whenBeginTimeIsDerived_thenBeginEqualsLayerTime() {
        // given: 12.5 is exactly ten periods of 1.25
        let layerTime = 42.0
        // when
        let begin = LayerMotion.beginTime(layerTime: layerTime, referenceDate: 12.5, period: 1.25)
        // then
        #expect(abs(begin - 42) < 1e-9)
    }

    @Test func givenAdvancingClocks_whenBeginTimeIsRederived_thenPhaseAdvancesInStep() {
        // given: two instants 0.25 s apart on both clocks
        let (firstLayer, secondLayer) = (10.0, 10.25)
        // when
        let first = LayerMotion.beginTime(layerTime: firstLayer, referenceDate: 500.1, period: 1.2)
        let second = LayerMotion.beginTime(layerTime: secondLayer, referenceDate: 500.35, period: 1.2)
        // then: the animation's start does not move, so the phase advanced with the clocks.
        #expect(abs(first - second) < 1e-9)
    }

    @Test func givenCaretCurve_whenSampled_thenMatchesTheCosineAndPeriod() {
        // given
        let period = StreamingCaret.period
        // when
        let samples = [0.0, 0.3, 0.6, 1.2].map { StreamingCaret.opacity(atPhase: $0) }
        // then
        #expect(period == 1.2)
        #expect(abs(samples[0] - 1) < 1e-12)
        #expect(abs(samples[1] - 0.6) < 1e-12)
        #expect(abs(samples[2] - 0.2) < 1e-12)
        #expect(abs(samples[3] - 1) < 1e-12)
        for step in 0 ..< 200 {
            let phase = Double(step) * 0.0137
            let value = StreamingCaret.opacity(atPhase: phase)
            #expect(value >= 0.2 - 1e-12 && value <= 1 + 1e-12)
            #expect(abs(value - StreamingCaret.opacity(atPhase: phase + StreamingCaret.period)) < 1e-9)
        }
    }

    @Test func givenTwentyFourLinearKeyframes_whenComparedWithTheCosine_thenDeviationStaysUnderOneLevel() {
        // given
        let steps = LayerCaretView.keyframeSteps
        let values = (0 ... steps).map { StreamingCaret.opacity(atPhase: StreamingCaret.period * Double($0) / Double(steps)) }
        // when
        var worst = 0.0
        for sample in 0 ... 2400 {
            let fraction = Double(sample) / 2400
            let scaled = fraction * Double(steps)
            let low = min(Int(scaled), steps - 1)
            let interpolated = values[low] + (values[low + 1] - values[low]) * (scaled - Double(low))
            worst = max(worst, abs(interpolated - StreamingCaret.opacity(atPhase: StreamingCaret.period * fraction)))
        }
        // then 0.4 * (1 - cos(pi / 24)) = 0.00342, below one 8-bit level (0.0039)
        #expect(steps == 24)
        #expect(worst < 0.0035)
        #expect(worst < 1.0 / 255)
    }

    @Test func givenSpinnerSpec_whenSideIsRead_thenItIsDiameterPlusTwiceMargin() {
        // given
        let spec = LayerSpinnerSpec(diameter: 14, margin: 1, lineWidth: 2, arcFraction: 0.25, period: 1, ringColor: .red, arcColor: .blue)
        var other = spec
        // when
        let side = spec.side
        // then
        #expect(side == 16)
        #expect(spec == other)
        // when
        other.arcFraction = 0.3
        // then
        #expect(spec != other)
    }

    @Test func givenPulseConstants_whenRead_thenMatchTheFormerDot() {
        // given
        let (half, dimmed) = (LayerPulseDotView.halfPeriod, LayerPulseDotView.dimmedOpacity)
        // when
        let cycle = 2 * half
        // then: the former dot eased over 0.8 s each way to 30%
        #expect(half == 0.8)
        #expect(dimmed == 0.3)
        #expect(cycle == 1.6)
    }
}
