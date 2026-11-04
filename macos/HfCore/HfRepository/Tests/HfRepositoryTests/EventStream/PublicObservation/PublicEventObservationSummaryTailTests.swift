import Foundation
@testable import HfRepository
import HfTestUtilities
import Testing

// MARK: - PublicEventObservationSummaryTailTests

@Suite struct PublicEventObservationSummaryTailTests {
    @Test func givenCaughtUpSummary_whenAdvancingTailNeverCatchesUp_thenTwoPagesPauseUntilTickAndResumeOwnCursorWithoutHistoricalWork() async {
        // given
        let reader = ObservationScriptReader()
        let deliveries = LockedBox(0)
        let sut = PublicEventObservationSession(taskID: "task", reader: reader, scheduler: NullScheduling(),
            budget: EventInitialLoadQueue(limit: 2), delivery: { callback in callback(); deliveries.mutate { $0 += 1 } })
        defer { sut.stop() }
        sut.subscribe(id: UUID()) { _ in }
        await waitUntil { reader.requests.count == 1 }
        reader.finish(0, .success(ObservationFixtures.page(newer: "shared-bootstrap")))
        await waitUntil { reader.requests.count == 2 }
        reader.finish(1, .success(ObservationFixtures.page(newer: "summary-start")))
        await waitUntil { sut.snapshot.summaryPhase == .caughtUp }
        let historicalWork = sut.snapshot.historicalOperations
        // when
        sut.tick()
        await waitUntil { reader.requests.count == 3 }
        #expect(reader.requests[2].position == .cursor("shared-bootstrap"))
        reader.finish(2, .success(ObservationFixtures.page(newer: "activity-next")))
        await waitUntil { reader.requests.count == 4 }
        #expect(reader.requests[3].position == .cursor("summary-start"))
        reader.finish(3, .success(ObservationFixtures.page(newer: "summary-one", more: true)))
        await waitUntil { reader.requests.count == 5 }
        #expect(reader.requests[4].position == .cursor("summary-one"))
        let beforePause = deliveries.value
        reader.finish(4, .success(ObservationFixtures.page(newer: "summary-two", more: true)))
        // Apply publication and the yielded idle pump prove that the bounded turn has ended.
        await waitUntil { deliveries.value >= beforePause + 2 }
        // then
        #expect(reader.requests.count == 5)
        #expect(sut.snapshot.summaryPhase == .replaying)
        #expect(sut.snapshot.summaryDeliveryCursor == "summary-two")
        #expect(sut.snapshot.summary.counts == nil)
        #expect(sut.snapshot.historicalOperations == historicalWork)
        sut.tick()
        await waitUntil { reader.requests.count == 6 }
        #expect(reader.requests[5].position == .cursor("activity-next"))
        reader.finish(5, .success(ObservationFixtures.page(newer: "activity-after-resume")))
        await waitUntil { reader.requests.count == 7 }
        #expect(reader.requests[6].position == .cursor("summary-two"))
        #expect(sut.snapshot.historicalOperations == historicalWork)
        sut.stop()
        reader.finish(6, .success(ObservationFixtures.page(newer: "summary-three", more: true)))
    }
}
