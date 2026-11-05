import Foundation
@testable import HfRepository
import HfTestUtilities
import MonitorCore
import Testing

// MARK: - PublicEventObservationRecoveryTests

@Suite struct PublicEventObservationRecoveryTests {
    @Test func givenCursorRefusal_whenCurrentActivityIsExplicitlyAdopted_thenCachedRowsRemainUntilNewWindowStarts() async {
        // given
        let reader = ObservationScriptReader()
        let sut = makeSession(reader)
        defer { sut.stop() }
        sut.subscribe(id: UUID()) { _ in }
        await waitUntil { reader.requests.count == 1 }
        reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.record(7)], newer: "first", capture: "future_capture")))
        await waitUntil { sut.snapshot.liveCursor == "first" }
        let retained = sut.snapshot
        // when
        sut.tick()
        await waitUntil { reader.requests.count == 2 }
        reader.finish(1, .failure(.refused(code: "cursor_expired", message: "expired")))
        await waitUntil { sut.snapshot.sourceChangePending }
        // then
        #expect(sut.snapshot.activity == retained.activity)
        #expect(sut.snapshot.epoch == retained.epoch)
        #expect(sut.snapshot.windowID == retained.windowID)
        #expect(sut.snapshot.liveCursor == "first")
        #expect(sut.snapshot.summary.counts == nil)
        #expect(reader.requests.count == 2)
        sut.adoptCurrentActivity()
        await waitUntil { reader.requests.count == 3 }
        #expect(reader.requests[2].position == .newest)
        #expect(sut.snapshot.epoch != retained.epoch)
        #expect(sut.snapshot.windowID != retained.windowID)
        reader.finish(2, .success(ObservationFixtures.page([ObservationFixtures.record(7)], newer: "second")))
        await waitUntil { sut.snapshot.liveCursor == "second" }
        #expect(sut.snapshot.activity.count == 1)
        #expect(sut.snapshot.activity.first?.epoch != retained.activity.first?.epoch)
        #expect(sut.snapshot.summary.counts == nil)
        #expect(sut.snapshot.coverage == retained.coverage)
        #expect(sut.snapshot.historicalOperations == retained.historicalOperations + 1)
        sut.tick()
        await waitUntil { reader.requests.count == 4 }
        reader.finish(3, .failure(.refused(code: "cursor_invalid", message: "invalid again")))
        await waitUntil { sut.snapshot.sourceChangePending }
        let exhausted = sut.snapshot
        sut.adoptCurrentActivity()
        await waitUntil { sut.snapshot.issues.contains(.resetExhausted) }
        #expect(sut.snapshot.activity == exhausted.activity)
        #expect(sut.snapshot.windowID == exhausted.windowID)
        #expect(sut.snapshot.historicalOperations == exhausted.historicalOperations)
        #expect(reader.requests.count == 4)
    }

    @Test func givenQueuedOldPublication_whenSourceIsAdopted_thenOnlyCurrentWindowCanReachSubscribers() async {
        // given
        let reader = ObservationScriptReader()
        let mailbox = ObservationMailbox()
        let sut = makeSession(reader, delivery: mailbox.enqueue)
        defer { sut.stop() }
        sut.subscribe(id: UUID(), publish: mailbox.publish)
        await waitUntil { reader.requests.count == 1 && mailbox.pendingCount == 1 }
        reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.record(1)], newer: "old", capture: "future_capture")))
        await waitUntil { sut.snapshot.liveCursor == "old" }
        let oldWindow = sut.snapshot.windowID
        sut.tick()
        await waitUntil { reader.requests.count == 2 }
        reader.finish(1, .failure(.refused(code: "cursor_invalid", message: "changed")))
        await waitUntil { sut.snapshot.sourceChangePending }
        // when
        sut.adoptCurrentActivity()
        await waitUntil { reader.requests.count == 3 }
        #expect(!reader.requests[1].isCurrent())
        reader.finish(2, .success(ObservationFixtures.page([ObservationFixtures.record(1)], newer: "new")))
        await waitUntil { sut.snapshot.liveCursor == "new" }
        mailbox.flush()
        mailbox.flush()
        // then
        #expect(!mailbox.values.isEmpty)
        #expect(mailbox.values.allSatisfy { $0.windowID != oldWindow })
        #expect(mailbox.values.last?.windowID == sut.snapshot.windowID)
        #expect(mailbox.values.last?.activity == sut.snapshot.activity)
    }

    @Test func givenCaughtUpSummary_whenUnchangedLiveAndSummaryPollComplete_thenPublicationsStayQuietAndHistoricalWorkDoesNotIncrease() async {
        // given
        let reader = ObservationScriptReader()
        let mailbox = ObservationMailbox()
        let sut = makeSession(reader, delivery: mailbox.enqueue)
        defer { sut.stop() }
        sut.subscribe(id: UUID(), publish: mailbox.publish)
        await waitUntil { reader.requests.count == 1 }
        reader.finish(0, .success(ObservationFixtures.page(newer: "same")))
        await waitUntil { reader.requests.count == 2 }
        #expect(reader.requests[1].position == .cursor("same"))
        reader.finish(1, .success(ObservationFixtures.page(newer: "same")))
        await waitUntil { sut.snapshot.summaryPhase == .caughtUp }
        mailbox.flush()
        let original = sut.snapshot
        let publications = mailbox.values.count
        // when
        sut.tick()
        await waitUntil { reader.requests.count == 3 }
        reader.finish(2, .success(ObservationFixtures.page(newer: "same")))
        await waitUntil { reader.requests.count == 4 }
        reader.finish(3, .success(ObservationFixtures.page(newer: "same")))
        // A manual live demand acts as a serial barrier after both unchanged completions.
        sut.tick()
        await waitUntil { reader.requests.count == 5 }
        mailbox.flush()
        // then
        #expect(sut.snapshot == original)
        #expect(mailbox.values.count == publications)
        #expect(sut.snapshot.historicalOperations == original.historicalOperations)
        sut.stop()
        reader.finish(4, .success(ObservationFixtures.page(newer: "same")))
    }

    @Test func givenAllThreeLanesDemanded_whenLiveDrainContinues_thenOlderAndSummaryEachReceiveATurn() async {
        // given
        let reader = ObservationScriptReader()
        let sut = makeSession(reader)
        defer { sut.stop() }
        sut.subscribe(id: UUID()) { _ in }
        await waitUntil { reader.requests.count == 1 }
        sut.requestOlder()
        sut.tick()
        // when
        reader.finish(0, .success(ObservationFixtures.page(older: "history", newer: "live", more: true)))
        await waitUntil { reader.requests.count == 2 }
        #expect(reader.requests[1].position == .cursor("live"))
        reader.finish(1, .success(ObservationFixtures.page(older: "history", newer: "live-next", more: true)))
        await waitUntil { reader.requests.count == 3 }
        #expect(reader.requests[2].position == .cursor("history"))
        reader.finish(2, .success(ObservationFixtures.page(newer: "unused")))
        await waitUntil { reader.requests.count == 4 }
        // then
        #expect(reader.requests[3].position == .cursor("history"))
        sut.stop()
        reader.finish(3, .success(ObservationFixtures.page(newer: "unused")))
    }

    private func makeSession(_ reader: ObservationScriptReader,
                             delivery: @escaping PublicEventObservationSession.Delivery = { $0() }) -> PublicEventObservationSession {
        PublicEventObservationSession(taskID: "task", reader: reader, scheduler: NullScheduling(),
            budget: EventInitialLoadQueue(limit: 2), delivery: delivery)
    }
}
