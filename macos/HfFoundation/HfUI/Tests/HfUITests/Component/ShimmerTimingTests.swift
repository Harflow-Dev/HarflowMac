import Foundation
@testable import HfUI
import Testing

// MARK: - ShimmerTimingTests

struct ShimmerTimingTests {
    @Test func givenSweepValues_whenSampled_thenTheyRunFromOneWidthLeftToOneWidthRight() throws {
        // given
        let width: CGFloat = 200

        // when
        let values = ShimmerTiming.sweepValues(width: width)

        // then
        #expect(values.count == ShimmerTiming.sweepSteps + 1)
        let first = try #require(values.first)
        let last = try #require(values.last)
        #expect(abs(first + width) < 0.001)
        #expect(abs(last - width) < 0.001)
    }

    @Test func givenSweepValues_whenReadAtTheMidpoint_thenTheSheenIsCentred() {
        // given
        let values = ShimmerTiming.sweepValues(width: 100)

        // when
        let middle = values[ShimmerTiming.sweepSteps / 2]

        // then
        #expect(abs(middle) < 0.001)
    }

    @Test func givenSweepValues_whenCompared_thenTheyNeverMoveBackwards() {
        // given / when
        let values = ShimmerTiming.sweepValues(width: 100)

        // then
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func givenTheShimmerConstants_whenRead_thenTheyMatchTheDesign() {
        // given / when / then
        #expect(ShimmerTiming.sweepPeriod == 1.4)
        #expect(ShimmerTiming.pulseHalfPeriod == 0.8)
        #expect(ShimmerTiming.pulseLowOpacity == 0.55)
    }

    @Test func givenClockPhaseHelper_whenBeginTimeDerived_thenLayerPhaseEqualsReferencePhase() {
        // given
        let period = 1.4
        let referenceDate = 12345.678
        let layerTime = 50.0

        // when
        let begin = HfLayerClock.beginTime(layerTime: layerTime, referenceDate: referenceDate, period: period)

        // then
        let layerPhase = (layerTime - begin).truncatingRemainder(dividingBy: period)
        #expect(abs(layerPhase - referenceDate.truncatingRemainder(dividingBy: period)) < 0.000001)
    }
}
