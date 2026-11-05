import Foundation
@testable import HfRepository
import HfTestUtilities
import MonitorCore
import Testing

// MARK: - PublicEventObservationFreshnessTests

@Suite struct PublicEventObservationFreshnessTests {
    @Test func givenDrainedTerminalWithKnownLoss_whenReadTimesOutAndRetryIsParked_thenCachedHistoryStaysReconnectingUntilFreshReadQualifiesIt() async {
        // given
        let reader = ObservationScriptReader()
        let sut = PublicEventObservationSession(taskID: "task", reader: reader, scheduler: NullScheduling(),
            budget: EventInitialLoadQueue(limit: 2), delivery: { $0() })
        defer { sut.stop() }
        sut.subscribe(id: UUID()) { _ in }
        await waitUntil { reader.requests.count == 1 }
        reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.record(1)], newer: "forward", malformed: 1)))
        await waitUntil { sut.snapshot.liveCursor == "forward" }
        sut.tick()
        await waitUntil { reader.requests.count == 2 }
        let finished = ObservationFixtures.record(9, "task_finished", ["status": .string("completed")])
        reader.finish(1, .success(ObservationFixtures.page([finished], newer: "final", final: 9)))
        await waitUntil { sut.snapshot.forwardDrained }
        let retained = sut.snapshot
        let initialFrame = project(retained)
        #expect(initialFrame.history.caughtUp)
        #expect(initialFrame.history.currentness == .current)
        #expect(initialFrame.history.reasons.contains(.skippedRecords))
        // when
        sut.tick()
        await waitUntil { reader.requests.count == 3 }
        let timeout = ToolError.timedOut(tool: "harflow-ctl", seconds: 20)
        reader.finish(2, .failure(timeout))
        await waitUntil { sut.snapshot.error == timeout }
        let failed = project(sut.snapshot)
        #expect(!failed.history.forwardDrained)
        #expect(!failed.history.caughtUp)
        #expect(failed.history.currentness == .reconnecting)
        #expect(failed.history.failure == timeout)
        #expect(failed.records == initialFrame.records)
        sut.retryObservation()
        await waitUntil { reader.requests.count == 4 }
        #expect(reader.requests[3].position == .cursor("final"))
        let retrying = project(sut.snapshot)
        // then — merely starting the observation retry cannot refresh cached evidence.
        #expect(retrying.history.failure == timeout)
        #expect(retrying.history.currentness == .reconnecting)
        #expect(!retrying.history.caughtUp)
        #expect(!retrying.history.forwardDrained)
        #expect(retrying.records == initialFrame.records)
        #expect(retrying.summary.counts == nil)
        #expect(retrying.history.reasons.contains(.skippedRecords))
        reader.finish(3, .success(ObservationFixtures.page(newer: "fresh-final", final: 9)))
        await waitUntil { sut.snapshot.liveCursor == "fresh-final" && sut.snapshot.forwardDrained }
        let recovered = project(sut.snapshot)
        #expect(recovered.history.failure == nil)
        #expect(recovered.history.currentness == .current)
        #expect(recovered.history.caughtUp)
        #expect(recovered.history.forwardDrained)
        #expect(recovered.records == initialFrame.records)
        #expect(recovered.scope == initialFrame.scope)
        #expect(recovered.history.reasons.contains(.skippedRecords))
        #expect(recovered.summary.counts == nil)
        #expect(sut.snapshot.coverage == retained.coverage)
        #expect(reader.requests.count == 4)
    }

    private func project(_ snapshot: PublicEventObservationSnapshot) -> EventObservationFrame {
        EventObservationFrameProjector.project(taskID: "task", snapshot: snapshot)
    }
}
