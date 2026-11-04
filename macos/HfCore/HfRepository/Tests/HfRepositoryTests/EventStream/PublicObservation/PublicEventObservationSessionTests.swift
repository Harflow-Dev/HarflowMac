import Foundation
@testable import HfRepository
import HfTestUtilities
import MonitorCore
import Testing

// MARK: - PublicEventObservationSessionTests

@Suite struct PublicEventObservationSessionTests {
    @Test func givenNewestBootstrapWithHistory_whenSeekingThenReplaying_thenAllRequestsStayInOneLineageAndFoldChronologically() async {
        // given
        let reader = ObservationScriptReader()
        let sut = makeSession(reader)
        defer { sut.stop() }
        sut.subscribe(id: UUID()) { _ in }
        await waitUntil { reader.requests.count == 1 }
        #expect(reader.requests[0].position == .newest)
        // when
        reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.result(3, id: "edit", ok: true)], older: "seek", newer: "live")))
        await waitUntil { reader.requests.count == 2 }
        #expect(reader.requests[1].position == .cursor("seek"))
        reader.finish(1, .success(ObservationFixtures.page([ObservationFixtures.call(1, id: "edit", path: "a")], newer: "replay", more: true)))
        await waitUntil { reader.requests.count == 3 }
        #expect(reader.requests[2].position == .cursor("replay"))
        reader.finish(2, .success(ObservationFixtures.page([ObservationFixtures.result(3, id: "edit", ok: true)], older: "seek", newer: "live")))
        await waitUntil { sut.snapshot.summaryPhase == .caughtUp }
        // then
        #expect(sut.snapshot.summary.counts?.edits == 1)
        #expect(sut.snapshot.summary.files == [EditedFile(path: "a", status: .edited)])
        #expect(sut.snapshot.activity.map(\.record.seq) == [3])
        #expect(!reader.requests.contains { $0.position == .oldest })
    }

    @Test func givenRawAmbiguousSequence_whenBootstrapAdmitted_thenRawOrderSurvivesAndSummaryIsUnavailable() async {
        // given
        let reader = ObservationScriptReader()
        let sut = makeSession(reader)
        defer { sut.stop() }
        sut.subscribe(id: UUID()) { _ in }
        await waitUntil { reader.requests.count == 1 }
        // when
        reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.record(4), ObservationFixtures.record(4), ObservationFixtures.record(2)])))
        await waitUntil { sut.snapshot.activity.count == 3 }
        // then
        #expect(sut.snapshot.activity.map(\.record.seq) == [4, 4, 2])
        #expect(Set(sut.snapshot.activity.map(\.admission)).count == 3)
        #expect(sut.snapshot.summary.counts == nil)
        #expect(sut.snapshot.summary.issues.contains(.ambiguousOrder))
    }

    @Test func givenEmptyForwardPage_whenCursorAdvances_thenNextTickUsesReturnedCursor() async {
        // given
        let reader = ObservationScriptReader()
        let sut = makeSession(reader)
        defer { sut.stop() }
        sut.subscribe(id: UUID()) { _ in }
        await waitUntil { reader.requests.count == 1 }
        reader.finish(0, .success(ObservationFixtures.page(newer: "one", capture: "future_capture")))
        await waitUntil { sut.snapshot.liveCursor == "one" }
        // when
        sut.tick()
        await waitUntil { reader.requests.count >= 2 }
        #expect(reader.requests[1].position == .cursor("one"))
        reader.finish(1, .success(ObservationFixtures.page(newer: "two")))
        await waitUntil { sut.snapshot.liveCursor == "two" }
        sut.stop()
        // then
        #expect(sut.snapshot.activity.isEmpty)
        #expect(sut.snapshot.liveCursor == "two")
    }

    @Test func givenQueuedPublicationAndInflightRead_whenRuntimeInvalidates_thenLateSuccessAndQueuedCallbacksAreRejected() async {
        // given
        let reader = ObservationScriptReader()
        let mailbox = ObservationMailbox()
        let sut = makeSession(reader, delivery: mailbox.enqueue)
        sut.subscribe(id: UUID(), publish: mailbox.publish)
        await waitUntil { reader.requests.count == 1 && mailbox.pendingCount == 1 }
        let epoch = sut.snapshot.epoch
        // when
        sut.invalidateRuntime()
        #expect(!reader.requests[0].isCurrent())
        reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.record(1)])))
        mailbox.flush()
        // then
        #expect(sut.snapshot.epoch != epoch)
        #expect(sut.snapshot.stopped)
        #expect(sut.snapshot.activity.isEmpty)
        #expect(mailbox.values.isEmpty)
    }

    @Test func givenQueuedPublicationAndInflightRead_whenStopped_thenLateErrorCannotReviveObservation() async {
        // given
        let reader = ObservationScriptReader()
        let mailbox = ObservationMailbox()
        let sut = makeSession(reader, delivery: mailbox.enqueue)
        sut.subscribe(id: UUID(), publish: mailbox.publish)
        await waitUntil { reader.requests.count == 1 }
        // when
        sut.stop()
        reader.finish(0, .failure(.unreadable(tool: "harflow-ctl", exitCode: 1, stderr: "late")))
        mailbox.flush()
        // then
        #expect(sut.snapshot.error == nil)
        #expect(sut.snapshot.stopped)
        #expect(mailbox.values.isEmpty)
    }

    @Test func givenTerminalForwardPage_whenPublished_thenFinalRecordIsPresentInSameSnapshotAsDrainedState() async {
        // given
        let reader = ObservationScriptReader()
        let mailbox = ObservationMailbox()
        let sut = makeSession(reader, delivery: mailbox.enqueue)
        defer { sut.stop() }
        sut.subscribe(id: UUID(), publish: mailbox.publish)
        await waitUntil { reader.requests.count == 1 }
        // when
        reader.finish(0, .success(ObservationFixtures.page(newer: "forward", capture: "future_capture")))
        await waitUntil { sut.snapshot.liveCursor == "forward" }
        sut.tick()
        await waitUntil { reader.requests.count == 2 }
        reader.finish(1, .success(ObservationFixtures.page([ObservationFixtures.record(9, "task_finished", ["status": .string("completed")])], final: 9)))
        await waitUntil { sut.snapshot.forwardDrained }
        mailbox.flush()
        // then
        #expect(mailbox.values.last?.forwardDrained == true)
        #expect(mailbox.values.last?.activity.last?.record.seq == 9)
        #expect(mailbox.pendingCount == 0)
    }

    private func makeSession(_ reader: ObservationScriptReader,
                             delivery: @escaping PublicEventObservationSession.Delivery = { $0() }) -> PublicEventObservationSession {
        PublicEventObservationSession(taskID: "task", reader: reader, scheduler: NullScheduling(),
            budget: EventInitialLoadQueue(limit: 2), delivery: delivery)
    }
}
