import Foundation
@testable import HfRepository
import HfTestUtilities
import MonitorCore
import Testing

// MARK: - PublicEventObservationWindowRecoveryTests

@Suite struct PublicEventObservationWindowRecoveryTests {
    @Test func givenFailedLiveRead_whenTicksArrive_thenOnlyExplicitRetryReadsAgainAndRetainsLoss() async {
        // given
        let reader = ObservationScriptReader()
        let sut = makeSession(reader)
        defer { sut.stop() }
        sut.subscribe(id: UUID()) { _ in }
        await waitUntil { reader.requests.count == 1 }
        reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.record(1)], newer: "live", malformed: 1)))
        await waitUntil { sut.snapshot.liveCursor == "live" }
        let retained = sut.snapshot
        sut.tick()
        await waitUntil { reader.requests.count == 2 }
        reader.finish(1, .failure(.unreadable(tool: "harflow-ctl", exitCode: 1, stderr: "offline")))
        await waitUntil { sut.snapshot.error != nil }
        // when
        for _ in 0 ..< 10 { sut.tick() }
        sut.retryObservation()
        await waitUntil { reader.requests.count == 3 }
        #expect(reader.requests[2].position == .cursor("live"))
        reader.finish(2, .success(ObservationFixtures.page([ObservationFixtures.record(2)], newer: "next")))
        await waitUntil { sut.snapshot.liveCursor == "next" }
        // then
        #expect(sut.snapshot.activity.map(\.record.seq) == [1, 2])
        #expect(sut.snapshot.epoch == retained.epoch)
        #expect(sut.snapshot.windowID == retained.windowID)
        #expect(sut.snapshot.coverage.malformed == 1)
        #expect(sut.snapshot.summary.counts == nil)
        #expect(sut.snapshot.historicalOperations == retained.historicalOperations)
        #expect(reader.requests.count == 3)
    }

    @Test func givenNonprogress_whenExplicitRetrySucceeds_thenCursorAndOccurrenceContinuityArePreserved() async {
        // given
        let reader = ObservationScriptReader()
        let sut = makeSession(reader)
        defer { sut.stop() }
        sut.subscribe(id: UUID()) { _ in }
        await waitUntil { reader.requests.count == 1 }
        reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.record(7, "future_kind")], newer: "same", more: true)))
        await waitUntil { reader.requests.count == 2 }
        reader.finish(1, .success(ObservationFixtures.page(newer: "same", more: true)))
        await waitUntil { sut.snapshot.issues.contains(.nonprogress) }
        let retained = sut.snapshot
        // when
        for _ in 0 ..< 10 { sut.tick() }
        sut.retryObservation()
        await waitUntil { reader.requests.count == 3 }
        #expect(reader.requests[2].position == .cursor("same"))
        reader.finish(2, .success(ObservationFixtures.page([ObservationFixtures.record(7)], newer: "advanced")))
        await waitUntil { sut.snapshot.liveCursor == "advanced" }
        // then
        #expect(sut.snapshot.activity.first == retained.activity.first)
        #expect(sut.snapshot.activity.map(\.record.seq) == [7, 7])
        #expect(Set(sut.snapshot.activity.map(\.admission)).count == 2)
        #expect(sut.snapshot.windowID == retained.windowID)
        #expect(sut.snapshot.summary.counts == nil)
        #expect(reader.requests.count == 3)
    }

    @Test func givenCapacityWithSoundSummary_whenWindowIsAdopted_thenSummaryFrontierAndProducerEpochRemainIndependent() async {
        // given
        let reader = ObservationScriptReader()
        let sut = makeSession(reader)
        defer { sut.stop() }
        sut.subscribe(id: UUID()) { _ in }
        await waitUntil { reader.requests.count == 1 }
        let text = String(repeating: "x", count: 15000)
        let notices = (3 ... 200).map { ObservationFixtures.record($0, "notice", ["text": .string(text)]) }
        let original = [ObservationFixtures.call(1, id: "edit", path: "file"), ObservationFixtures.result(2, id: "edit", ok: true)] + notices
        reader.finish(0, .success(ObservationFixtures.page(original, newer: "frontier")))
        await waitUntil { reader.requests.count == 2 }
        reader.finish(1, .success(ObservationFixtures.page(newer: "frontier")))
        await waitUntil { sut.snapshot.summaryPhase == .caughtUp }
        #expect(sut.snapshot.summary.counts?.edits == 1)
        sut.tick()
        await waitUntil { reader.requests.count == 3 }
        let excess = (201 ... 300).map { ObservationFixtures.record($0, "notice", ["text": .string(text)]) }
        reader.finish(2, .success(ObservationFixtures.page(excess, newer: "rejected")))
        await waitUntil { sut.snapshot.issues.contains(.capacity) }
        // The independently demanded summary tail receives its normal turn.
        await waitUntil { reader.requests.count == 4 }
        reader.finish(3, .success(ObservationFixtures.page(newer: "frontier")))
        await waitUntil { sut.snapshot.summaryPhase == .caughtUp }
        let retained = sut.snapshot
        // when
        sut.adoptCurrentActivity()
        await waitUntil { reader.requests.count == 5 }
        #expect(reader.requests[4].position == .newest)
        reader.finish(4, .success(ObservationFixtures.page([ObservationFixtures.record(200)], newer: "current")))
        await waitUntil { sut.snapshot.liveCursor == "current" }
        // then
        #expect(sut.snapshot.activity.map(\.record.seq) == [200])
        #expect(sut.snapshot.epoch == retained.epoch)
        #expect(sut.snapshot.windowID != retained.windowID)
        #expect(sut.snapshot.summary == retained.summary)
        #expect(sut.snapshot.summaryDeliveryCursor == retained.summaryDeliveryCursor)
        #expect(sut.snapshot.summaryPhase == .caughtUp)
        #expect(sut.snapshot.historicalOperations == retained.historicalOperations)
        #expect(reader.requests.filter { $0.position == .newest }.count == 2)
        #expect(reader.requests.count == 5)
    }

    private func makeSession(_ reader: ObservationScriptReader) -> PublicEventObservationSession {
        PublicEventObservationSession(taskID: "task", reader: reader, scheduler: NullScheduling(),
            budget: EventInitialLoadQueue(limit: 2), delivery: { $0() })
    }
}
