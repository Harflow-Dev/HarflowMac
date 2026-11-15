import Foundation
@testable import HfRepository
import HfTestUtilities
import MonitorCore
import Testing

// MARK: - PublicEventObservationOlderReadTests

@Suite struct PublicEventObservationOlderReadTests {
    private static let offline = ToolError.unreadable(tool: "harflow-ctl", exitCode: 1, stderr: "offline")

    @Test func givenOlderPageReadFails_whenProjected_thenFlagIsSetAndRetryIsOfferedWithRecordsRetained() async {
        // given
        let reader = ObservationScriptReader()
        let (sut, next) = await makeIdleSession(reader)
        defer { sut.stop() }
        // when
        await failOlderRead(sut, reader, index: next)
        // then
        let frame = project(sut.snapshot)
        #expect(frame.history.olderReadFailed)
        #expect(frame.history.availableActions.contains(.retryRead))
        #expect(!frame.history.availableActions.contains(.rebaseWindow))
        #expect(frame.history.failure == Self.offline)
        #expect(frame.records.map(\.record.seq) == [1])
    }

    @Test func givenOlderPageReadFails_whenRetryStartsAndOlderReadSucceeds_thenFlagAndRetryStayUntilItCompletesThenClear() async {
        // given
        let reader = ObservationScriptReader()
        let mailbox = ObservationMailbox()
        let (sut, next) = await makeIdleSession(reader, delivery: { $0() }, publish: mailbox.publish)
        defer { sut.stop() }
        await failOlderRead(sut, reader, index: next)
        // when — starting the retry changes no published fact.
        sut.retryObservation()
        // then
        let started = project(sut.snapshot)
        #expect(started.history.olderReadFailed)
        #expect(started.history.availableActions.contains(.retryRead))
        // when — the older read is the one outstanding read.
        let olderIndex = await serveOtherLanes(reader, after: next)
        #expect(reader.requests[olderIndex].position == .cursor("history"))
        reader.finish(olderIndex, .success(ObservationFixtures.page([ObservationFixtures.record(0)], newer: "live")))
        await waitUntil { sut.snapshot.activity.count == 2 }
        // then
        let recovered = project(sut.snapshot)
        #expect(!recovered.history.olderReadFailed)
        #expect(!recovered.history.availableActions.contains(.retryRead))
        #expect(recovered.records.map(\.record.seq) == [0, 1])
        await waitUntil { mailbox.values.last?.olderReadPaused == false }
        #expect(mailbox.values.last?.olderReadPaused == false)
    }

    @Test func givenOlderRetryInFlight_whenOtherLanesComplete_thenFlagAndRetryStayUntilOlderReadCompletes() async {
        // given
        let reader = ObservationScriptReader()
        let (sut, next) = await makeIdleSession(reader)
        defer { sut.stop() }
        await failOlderRead(sut, reader, index: next)
        // when — the summary and live reads complete while the older read is outstanding.
        sut.retryObservation()
        let olderIndex = await serveOtherLanes(reader, after: next)
        await waitUntil { !sut.snapshot.pausedReads && sut.snapshot.historyLoading }
        // then
        #expect(olderIndex > next + 1)
        #expect(sut.snapshot.olderReadPaused)
        let inFlight = project(sut.snapshot)
        #expect(inFlight.history.olderReadFailed)
        #expect(inFlight.history.availableActions.contains(.retryRead))
        // when
        reader.finish(olderIndex, .success(ObservationFixtures.page([ObservationFixtures.record(0)], newer: "live")))
        await waitUntil { sut.snapshot.activity.count == 2 }
        // then
        let recovered = project(sut.snapshot)
        #expect(!sut.snapshot.olderReadPaused)
        #expect(!recovered.history.olderReadFailed)
        #expect(!recovered.history.availableActions.contains(.retryRead))
    }

    @Test func givenOlderPageReadFails_whenRetryFailsAgain_thenFlagIsReportedAgain() async {
        // given
        let reader = ObservationScriptReader()
        let (sut, next) = await makeIdleSession(reader)
        defer { sut.stop() }
        await failOlderRead(sut, reader, index: next)
        // when
        sut.retryObservation()
        let olderIndex = await serveOtherLanes(reader, after: next)
        let before = sut.snapshot.revision
        reader.finish(olderIndex, .failure(Self.offline))
        await waitUntil { sut.snapshot.revision > before && !sut.snapshot.historyLoading && sut.snapshot.error == Self.offline }
        // then
        #expect(sut.snapshot.olderReadPaused)
        let frame = project(sut.snapshot)
        #expect(frame.history.olderReadFailed)
        #expect(frame.history.availableActions.contains(.retryRead))
    }

    @Test func givenOlderPageReadFails_whenLiveReadIsRejectedForCapacity_thenFlagIsNotReported() async {
        // given
        let reader = ObservationScriptReader()
        let text = String(repeating: "x", count: 15000)
        let large = (1 ... 200).map { ObservationFixtures.record($0, "notice", ["text": .string(text)]) }
        let (sut, next) = await makeIdleSession(reader, events: large)
        defer { sut.stop() }
        await failOlderRead(sut, reader, index: next)
        #expect(sut.snapshot.olderReadPaused)
        // when — the live and summary lanes each take one read; the live page does not fit.
        let excess = (201 ... 300).map { ObservationFixtures.record($0, "notice", ["text": .string(text)]) }
        sut.tick()
        await waitUntil { reader.requests.count == next + 2 }
        reader.finish(next + 1, .success(ObservationFixtures.page(excess, newer: "rejected")))
        await waitUntil { reader.requests.count == next + 3 }
        reader.finish(next + 2, .success(ObservationFixtures.page(excess, newer: "rejected")))
        await waitUntil { sut.snapshot.issues.contains(.capacity) }
        // then
        let frame = project(sut.snapshot)
        #expect(!sut.snapshot.olderReadPaused)
        #expect(!frame.history.olderReadFailed)
        #expect(frame.history.availableActions.contains(.rebaseWindow))
    }

    @Test func givenOlderPageReadFails_whenActivityIsDisabledAndNextReadCompletes_thenFlagIsNotReported() async {
        // given
        let reader = ObservationScriptReader()
        let (sut, next) = await makeIdleSession(reader)
        defer { sut.stop() }
        await failOlderRead(sut, reader, index: next)
        // when
        sut.setActivityEnabled(false)
        sut.tick()
        await waitUntil { reader.requests.count == next + 2 }
        reader.finish(next + 1, .success(ObservationFixtures.page(newer: "live")))
        await waitUntil { !sut.snapshot.olderReadPaused }
        // then
        #expect(!project(sut.snapshot).history.olderReadFailed)
    }

    @Test func givenOlderPageReadFailsThenCapacityRefusal_whenCurrentActivityIsAdopted_thenFlagStaysClear() async {
        // given
        let reader = ObservationScriptReader()
        let text = String(repeating: "x", count: 15000)
        let large = (1 ... 200).map { ObservationFixtures.record($0, "notice", ["text": .string(text)]) }
        let (sut, next) = await makeIdleSession(reader, events: large)
        defer { sut.stop() }
        await failOlderRead(sut, reader, index: next)
        let excess = (201 ... 300).map { ObservationFixtures.record($0, "notice", ["text": .string(text)]) }
        sut.tick()
        await waitUntil { reader.requests.count == next + 2 }
        reader.finish(next + 1, .success(ObservationFixtures.page(excess, newer: "rejected")))
        await waitUntil { reader.requests.count == next + 3 }
        reader.finish(next + 2, .success(ObservationFixtures.page(excess, newer: "rejected")))
        await waitUntil { sut.snapshot.issues.contains(.capacity) }
        // when
        sut.adoptCurrentActivity()
        await waitUntil { reader.requests.count == next + 4 }
        #expect(reader.requests[next + 3].position == .newest)
        // then — cleared before the replacement window reads its first page.
        #expect(!sut.snapshot.olderReadPaused)
        #expect(!project(sut.snapshot).history.olderReadFailed)
        reader.finish(next + 3, .success(ObservationFixtures.page([ObservationFixtures.record(300)], older: "fresh-history", newer: "fresh")))
        await waitUntil { sut.snapshot.liveCursor == "fresh" }
        #expect(!sut.snapshot.olderReadPaused)
    }

    @Test func givenOlderPageReadFails_whenSourceChangeIsAdopted_thenFlagIsCleared() async {
        // given
        let reader = ObservationScriptReader()
        let (sut, next) = await makeIdleSession(reader)
        defer { sut.stop() }
        await failOlderRead(sut, reader, index: next)
        sut.tick()
        await waitUntil { reader.requests.count == next + 2 }
        reader.finish(next + 1, .failure(.refused(code: "cursor_expired", message: "expired")))
        await waitUntil { sut.snapshot.sourceChangePending }
        #expect(!sut.snapshot.olderReadPaused)
        // when
        sut.adoptCurrentActivity()
        await waitUntil { reader.requests.contains { $0.position == .newest } && reader.requests.count >= next + 3 }
        // then
        #expect(!sut.snapshot.olderReadPaused)
        #expect(!sut.snapshot.sourceChangePending)
        #expect(!project(sut.snapshot).history.olderReadFailed)
    }

    @Test func givenOlderPageReadFails_whenRuntimeIsFenced_thenFlagIsClearAndNoActionsAreOffered() async {
        // given
        let reader = ObservationScriptReader()
        let (sut, next) = await makeIdleSession(reader)
        defer { sut.stop() }
        await failOlderRead(sut, reader, index: next)
        #expect(sut.snapshot.olderReadPaused)
        // when
        sut.fenceRuntime()
        // then
        let frame = project(sut.snapshot)
        #expect(!sut.snapshot.olderReadPaused)
        #expect(!frame.history.olderReadFailed)
        #expect(frame.history.availableActions.isEmpty)
    }

    @Test func givenOlderPageReadFails_whenAnotherLaneAlsoFails_thenFlagIsNotReported() async {
        // given
        let reader = ObservationScriptReader()
        let (sut, next) = await makeIdleSession(reader)
        defer { sut.stop() }
        await failOlderRead(sut, reader, index: next)
        // when — the summary and live lanes each take one read after a tick; both fail.
        sut.tick()
        await waitUntil { reader.requests.count == next + 2 }
        reader.finish(next + 1, .failure(Self.offline))
        await waitUntil { !sut.snapshot.olderReadPaused }
        // then
        #expect(!project(sut.snapshot).history.olderReadFailed)
        #expect(project(sut.snapshot).history.availableActions.contains(.retryRead))
        await waitUntil { reader.requests.count == next + 3 }
        reader.finish(next + 2, .failure(Self.offline))
        await waitUntil { sut.snapshot.error != nil }
        #expect(!sut.snapshot.olderReadPaused)
    }

    @Test func givenLiveReadFails_whenOlderPageWasNeverRequested_thenFlagIsNotReported() async {
        // given
        let reader = ObservationScriptReader()
        let (sut, next) = await makeIdleSession(reader)
        defer { sut.stop() }
        // when
        sut.tick()
        await waitUntil { reader.requests.count == next + 1 }
        reader.finish(next, .failure(Self.offline))
        await waitUntil { sut.snapshot.error != nil }
        // then
        let frame = project(sut.snapshot)
        #expect(!sut.snapshot.olderReadPaused)
        #expect(!frame.history.olderReadFailed)
        #expect(frame.history.availableActions.contains(.retryRead))
    }

    @Test func givenOlderLaneNonprogress_whenProjected_thenFlagIsReportedWithoutFailure() async {
        // given
        let reader = ObservationScriptReader()
        let (sut, next) = await makeIdleSession(reader)
        defer { sut.stop() }
        #expect(sut.requestOlder())
        await waitUntil { reader.requests.count == next + 1 }
        // when — the older page names the cursor it was read from.
        reader.finish(next, .success(ObservationFixtures.page(older: "history", newer: "live")))
        await waitUntil { sut.snapshot.issues.contains(.nonprogress) }
        // then
        let frame = project(sut.snapshot)
        #expect(sut.snapshot.error == nil)
        #expect(frame.history.failure == nil)
        #expect(frame.history.olderReadFailed)
        #expect(frame.history.availableActions.contains(.retryRead))
    }

    @Test func givenOlderLanePageWithUnavailableLog_whenProjected_thenFlagIsNotReported() async {
        // given
        let reader = ObservationScriptReader()
        let (sut, next) = await makeIdleSession(reader)
        defer { sut.stop() }
        #expect(sut.requestOlder())
        await waitUntil { reader.requests.count == next + 1 }
        // when
        reader.finish(next, .success(ObservationFixtures.page(state: .unavailable)))
        await waitUntil { sut.snapshot.issues.contains(.unavailable) }
        // then — the whole log is unavailable, not only the earlier page.
        let frame = project(sut.snapshot)
        #expect(sut.snapshot.error == nil)
        #expect(!sut.snapshot.olderReadPaused)
        #expect(!frame.history.olderReadFailed)
        #expect(frame.history.availableActions.contains(.retryRead))
    }

    @Test func givenOlderRetryInFlight_whenActivityIsDisabledAndReenabled_thenFlagAndRetryAreNotRestored() async {
        // given
        let reader = ObservationScriptReader()
        let (sut, next) = await makeIdleSession(reader)
        defer { sut.stop() }
        await failOlderRead(sut, reader, index: next)
        sut.retryObservation()
        await waitUntil { reader.requests.count == next + 2 }
        // when
        sut.setActivityEnabled(false)
        #expect(!sut.snapshot.olderReadPaused)
        reader.finish(next + 1, .success(ObservationFixtures.page(newer: "live")))
        await waitUntil { !sut.snapshot.pausedReads }
        sut.setActivityEnabled(true)
        sut.tick()
        await waitUntil { reader.requests.count == next + 3 }
        reader.finish(next + 2, .success(ObservationFixtures.page([ObservationFixtures.record(2)], newer: "live2")))
        await waitUntil { sut.snapshot.liveCursor == "live2" }
        // then — no older read was queued, and nothing offers a retry for one.
        let frame = project(sut.snapshot)
        #expect(!sut.snapshot.olderReadPaused)
        #expect(!frame.history.olderReadFailed)
        #expect(!frame.history.availableActions.contains(.retryRead))
        #expect(!reader.requests.dropFirst(next + 1).contains { $0.position == .cursor("history") })
    }

    @Test func givenTwoLanesFailed_whenRetryStarts_thenPageErrorIsNotReported() async {
        // given
        let reader = ObservationScriptReader()
        let (sut, next) = await makeIdleSession(reader)
        defer { sut.stop() }
        await failOlderRead(sut, reader, index: next)
        sut.tick()
        await waitUntil { reader.requests.count == next + 2 }
        reader.finish(next + 1, .failure(Self.offline))
        await waitUntil { !sut.snapshot.olderReadPaused && sut.snapshot.pausedReads }
        // when
        sut.retryObservation()
        let olderIndex = await serveOtherLanes(reader, after: next + 1)
        // then — the older read is outstanding but the retry did not start from an older-only failure.
        #expect(reader.requests[olderIndex].position == .cursor("history"))
        #expect(!sut.snapshot.olderReadPaused)
        #expect(!project(sut.snapshot).history.olderReadFailed)
    }

    // MARK: - Projector

    @Test func givenOlderReadPausedSnapshot_whenProjected_thenHistoryReportsFlagAndRetry() {
        // given
        var snapshot = PublicEventObservationSnapshot(sessionID: UUID())
        snapshot.olderCursor = "history"
        snapshot.pausedReads = true
        snapshot.olderReadPaused = true
        // when
        let frame = project(snapshot)
        // then
        #expect(frame.history.olderReadFailed)
        #expect(frame.history.availableActions.contains(.retryRead))
    }

    @Test func givenDefaultSnapshot_whenProjected_thenFlagIsClear() {
        // given
        let snapshot = PublicEventObservationSnapshot(sessionID: UUID())
        // when
        let frame = project(snapshot)
        // then
        #expect(!frame.history.olderReadFailed)
        #expect(!EventObservationHistory().olderReadFailed)
    }

    @Test func givenStoppedSnapshot_whenProjected_thenNoActionsAreOffered() {
        // given
        var snapshot = PublicEventObservationSnapshot(sessionID: UUID())
        snapshot.olderCursor = "history"
        snapshot.pausedReads = true
        snapshot.olderReadPaused = true
        snapshot.stopped = true
        // when
        let frame = project(snapshot)
        // then
        #expect(frame.history.availableActions.isEmpty)
        #expect(!frame.history.olderReadFailed)
    }

    // MARK: - Helpers

    /// Bootstraps one record page with an older cursor and brings the summary to caught up, so the session is idle.
    /// Returns the session and the index of the next request.
    private func makeIdleSession(_ reader: ObservationScriptReader,
                                 events: [[String: JSONValue]] = [ObservationFixtures.record(1)],
                                 delivery: @escaping PublicEventObservationSession.Delivery = { $0() },
                                 publish: @escaping PublicEventObservationSession.Publisher = { _ in })
        async -> (PublicEventObservationSession, Int) {
        let sut = PublicEventObservationSession(taskID: "task", reader: reader, scheduler: NullScheduling(),
            budget: EventInitialLoadQueue(limit: 2), delivery: delivery)
        sut.subscribe(id: UUID(), publish: publish)
        await waitUntil { reader.requests.count == 1 }
        reader.finish(0, .success(ObservationFixtures.page(events, older: "history", newer: "live")))
        await waitUntil { reader.requests.count == 2 }
        reader.finish(1, .success(ObservationFixtures.page(newer: "live")))
        await waitUntil { reader.requests.count == 3 }
        reader.finish(2, .success(ObservationFixtures.page(newer: "live")))
        await waitUntil { sut.snapshot.summaryPhase == .caughtUp }
        return (sut, 3)
    }

    /// After a retry, completes the live and summary reads that precede the older read and returns the older read's index.
    private func serveOtherLanes(_ reader: ObservationScriptReader, after index: Int) async -> Int {
        var current = index + 1
        while true {
            await waitUntil { reader.requests.count == current + 1 }
            if reader.requests[current].position == .cursor("history") { return current }
            reader.finish(current, .success(ObservationFixtures.page(newer: "live")))
            current += 1
        }
    }

    /// Requests the older page as request `index` and fails it.
    private func failOlderRead(_ sut: PublicEventObservationSession, _ reader: ObservationScriptReader, index: Int) async {
        #expect(sut.requestOlder())
        await waitUntil { reader.requests.count == index + 1 }
        #expect(reader.requests[index].position == .cursor("history"))
        reader.finish(index, .failure(Self.offline))
        await waitUntil { sut.snapshot.olderReadPaused }
    }

    private func project(_ snapshot: PublicEventObservationSnapshot) -> EventObservationFrame {
        EventObservationFrameProjector.project(taskID: "task", snapshot: snapshot)
    }
}
