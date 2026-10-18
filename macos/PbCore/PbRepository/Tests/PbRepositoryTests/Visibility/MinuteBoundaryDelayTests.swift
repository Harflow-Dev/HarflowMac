import Combine
import Foundation
@testable import PbRepository
import PbTestUtilities
import Testing

// MARK: - Minute alignment

@Suite struct MinuteBoundaryDelayTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test(arguments: [(0.0, 60.0), (20.0, 40.0), (59.5, 0.5)])
    func givenASecondWithinTheMinute_whenAligned_thenTheDelayReachesTheNextBoundary(second: Double, expected: Double) {
        // given — 2026-10-17 10:00:00 UTC plus `second`.
        let base = Date(timeIntervalSince1970: 1_792_231_200)
        let scheduler = CapturingScheduler()

        // when
        let delay = scheduler.minuteBoundaryDelay(after: base.addingTimeInterval(second), calendar: calendar)

        // then
        #expect(abs(delay - expected) < 0.001)
    }

    @Test func givenAnInstantJustBeforeTheBoundary_whenAligned_thenTheDelayNeverReachesZero() {
        // given
        let base = Date(timeIntervalSince1970: 1_792_231_200)
        let scheduler = CapturingScheduler()

        // when
        let delay = scheduler.minuteBoundaryDelay(after: base.addingTimeInterval(59.99999), calendar: calendar)

        // then
        #expect(delay >= 0.05)
    }
}
