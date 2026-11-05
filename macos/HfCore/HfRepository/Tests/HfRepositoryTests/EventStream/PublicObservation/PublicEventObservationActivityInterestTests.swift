import Foundation
@testable import HfRepository
import HfTestUtilities
import Testing

// MARK: - PublicEventObservationActivityInterestTests

@Suite struct PublicEventObservationActivityInterestTests {
    @Test func givenInitialBootstrapInFlight_whenActivityLeavesAndRejoins_thenReplacementWindowBootstrapsWithoutDoubleCountingSummary() async {
        // given
        let reader = ObservationScriptReader()
        let sut = makeSession(reader)
        defer { sut.stop() }
        sut.subscribe(id: UUID()) { _ in }
        await waitUntil { reader.requests.count == 1 }
        // when
        sut.setActivityEnabled(false)
        sut.setActivityEnabled(true)
        let page = ObservationFixtures.page([ObservationFixtures.call(1, id: "edit", path: "a")], newer: "summary-frontier")
        reader.finish(0, .success(page))
        await waitUntil { reader.requests.count == 2 }
        #expect(reader.requests[1].position == .newest)
        #expect(sut.snapshot.activity.isEmpty)
        reader.finish(1, .success(page))
        await waitUntil { reader.requests.count == 3 }
        #expect(reader.requests[2].position == .cursor("summary-frontier"))
        reader.finish(2, .success(ObservationFixtures.page(newer: "caught-up")))
        await waitUntil { sut.snapshot.summaryPhase == .caughtUp }
        // then
        #expect(sut.snapshot.activity.count == 1)
        #expect(sut.snapshot.liveCursor == "summary-frontier")
        #expect(sut.snapshot.summary.counts?.edits == 1)
    }

    @Test func givenSummaryOnlyInterest_whenActivityJoins_thenNewestCreatesWindowWithoutRefoldingSummary() async {
        // given
        let reader = ObservationScriptReader()
        let sut = makeSession(reader)
        defer { sut.stop() }
        sut.setActivityEnabled(false)
        sut.subscribe(id: UUID()) { _ in }
        await waitUntil { reader.requests.count == 1 }
        reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.call(1, id: "edit", path: "a")], newer: "summary-start")))
        await waitUntil { reader.requests.count == 2 }
        #expect(reader.requests[1].position == .cursor("summary-start"))
        reader.finish(1, .success(ObservationFixtures.page(newer: "summary-caught-up")))
        await waitUntil { sut.snapshot.summaryPhase == .caughtUp }
        let summary = sut.snapshot.summary
        let window = sut.snapshot.windowID
        #expect(summary.counts?.edits == 1)
        #expect(sut.snapshot.activity.isEmpty)
        #expect(sut.snapshot.liveCursor == nil)
        // when
        sut.setActivityEnabled(true)
        await waitUntil { reader.requests.count == 3 }
        #expect(reader.requests[2].position == .newest)
        reader.finish(2, .success(ObservationFixtures.page([ObservationFixtures.call(1, id: "edit", path: "a")], newer: "activity-start")))
        await waitUntil { sut.snapshot.liveCursor == "activity-start" }
        // then
        #expect(sut.snapshot.windowID != window)
        #expect(sut.snapshot.activity.count == 1)
        #expect(sut.snapshot.summary == summary)
        #expect(sut.snapshot.summaryDeliveryCursor == "summary-caught-up")
    }

    @Test func givenActivityReadInFlight_whenInterestEnds_thenResultDoesNotAdvanceRetainedWindow() async {
        // given
        let reader = ObservationScriptReader()
        let sut = makeSession(reader)
        defer { sut.stop() }
        sut.subscribe(id: UUID()) { _ in }
        await waitUntil { reader.requests.count == 1 }
        reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.record(1)], newer: "retained", capture: "future_capture")))
        await waitUntil { sut.snapshot.liveCursor == "retained" }
        let window = sut.snapshot.windowID
        sut.tick()
        await waitUntil { reader.requests.count == 2 }
        // when
        sut.setActivityEnabled(false)
        reader.finish(1, .success(ObservationFixtures.page([ObservationFixtures.record(2)], newer: "not-admitted")))
        sut.setActivityEnabled(true)
        await waitUntil { reader.requests.count == 3 }
        // then
        #expect(reader.requests[2].position == .cursor("retained"))
        #expect(sut.snapshot.windowID == window)
        #expect(sut.snapshot.activity.map(\.record.seq) == [1])
        sut.stop()
        reader.finish(2, .success(ObservationFixtures.page(newer: "finished")))
    }

    private func makeSession(_ reader: ObservationScriptReader) -> PublicEventObservationSession {
        PublicEventObservationSession(taskID: "task", reader: reader, scheduler: NullScheduling(),
            budget: EventInitialLoadQueue(limit: 2), delivery: { $0() })
    }
}
