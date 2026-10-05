import Combine
import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
import PbTestUtilities
import Testing

@Suite struct EventStreamRepositoryImplTests {

    /// A `MockScheduling` pre-stubbed with harmless defaults — used by every test that does not
    /// itself exercise the coalescing timer (see `TaskListRepositoryImplTests.defaultScheduler()`
    /// for why this lives in a factory rather than inside a shared `makeSUT`).
    private static func defaultScheduler() -> MockScheduling {
        let scheduler = MockScheduling()
        given(scheduler).now().willReturn(Date())
        given(scheduler).schedule(after: .any, execute: .any).willReturn(AnyCancellable {})
        given(scheduler).scheduleRepeating(every: .any, execute: .any).willReturn(AnyCancellable {})
        return scheduler
    }

    private func writeEventsFile(lines: [String]) -> (dir: URL, taskID: String, tasksDirectory: String) {
        let taskID = "evt-" + UUID().uuidString.prefix(8)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PbRepoTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("\(taskID).events.jsonl")
        try? (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
        return (dir, String(taskID), dir.path)
    }

    private func taskStartedLine(prompt: String = "hello") -> String {
        #"{"v":1,"seq":1,"kind":"task_started","prompt":"\#(prompt)","backend":"claude"}"#
    }

    @Test func givenLongLog_whenPaging_thenSummaryRemainsCumulativeAndPairingCrossesPages() async {
        let lines = (1 ... 250).map { seq -> String in
            if seq == 150 { return #"{"v":1,"seq":150,"kind":"tool_call","call_id":"edit","tool":"Edit","category":"edit", "#
                    + #""path":"/repo/a.swift","input_preview":""}"#
            }
            if seq == 151 { return #"{"v":1,"seq":151,"kind":"tool_result","call_id":"edit","ok":true,"output_tail":"done"}"# }
            return #"{"v":1,"seq":\#(seq),"kind":"assistant_text","text":"row"}"#
        }
        let (dir, id, tasksDir) = writeEventsFile(lines: lines)
        defer { try? FileManager.default.removeItem(at: dir) }
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(tasksDir)
        let snapshots = MockTaskSnapshotRepository()
        given(snapshots).refresh(.any).willReturn()
        let sut = EventStreamRepositoryImpl(toolEnvironment: environment, snapshotRepository: snapshots, scheduler: Self.defaultScheduler())
        let lease = sut.acquire(id)
        defer { lease.release() }
        await waitUntil { sut.events(for: id).count == 100 && sut.summary(for: id).availability == .available }
        #expect(sut.events(for: id).map(\.seq) == Array(151 ... 250))
        #expect(sut.summary(for: id).files == [EditedFile(path: "/repo/a.swift", status: .edited)])
        sut.loadMore(id)
        await waitUntil { sut.events(for: id).count == 200 }
        #expect(sut.items(for: id) == Timeline.items(from: lines.dropFirst(50).compactMap(TaskEvent.init(line:))))
        #expect(sut.summary(for: id).activity.edits == 1)
        sut.loadMore(id)
        await waitUntil { !sut.history(for: id).hasMore && sut.events(for: id).count == 250 }
        #expect(sut.events(for: id).map(\.seq) == Array(1 ... 250))
    }

    @Test func givenOnlySummaryInterest_whenAcquired_thenActivityIsNotSeeded() async {
        let (dir, id, tasksDir) = writeEventsFile(lines: [taskStartedLine()])
        defer { try? FileManager.default.removeItem(at: dir) }
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(tasksDir)
        let snapshots = MockTaskSnapshotRepository()
        given(snapshots).refresh(.any).willReturn()
        let sut = EventStreamRepositoryImpl(toolEnvironment: environment, snapshotRepository: snapshots, scheduler: Self.defaultScheduler())
        let lease = sut.acquireSummary(id)
        defer { lease.release() }
        await waitUntil { sut.summary(for: id).availability == .available }
        #expect(sut.events(for: id).isEmpty)
        #expect(sut.summary(for: id).prompt == "hello")
    }

    @Test func givenNoEventsPathExists_whenAcquiringAStream_thenItFallsBackToDevNull() async {
        // given — F4-13: `TaskTitle.eventsPath` returns nil for a task id that fails
        // `MonitorURL.isValidTaskID` (here, one containing "/"), so the tailer must fall back to
        // "/dev/null" rather than crash on a malformed path. The fallback path itself
        // (`TaskStream.path`) is private and not observable through the `EventStreamRepository` seam
        // without a production change, so this only proves the lease was really registered (ruling
        // out a no-op `acquire`) and that no events ever arrive.
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let snapshotRepository = MockTaskSnapshotRepository()
        given(snapshotRepository).refresh(.any).willReturn()
        let sut = EventStreamRepositoryImpl(toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository, scheduler: Self.defaultScheduler())

        // when
        let lease = sut.acquire("not/a-valid-id")

        // then — the lease was really registered...
        #expect(sut.leasedTaskIDs.contains("not/a-valid-id"))
        // ...and no crash, no events.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(sut.events(for: "not/a-valid-id").isEmpty)
        lease.release()
    }

    @Test func givenTheFirstLeaseOnATask_whenAcquired_thenItsSnapshotRefreshesAtOnce() async {
        // given
        let (dir, taskID, tasksDir) = writeEventsFile(lines: [taskStartedLine()])
        defer { try? FileManager.default.removeItem(at: dir) }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(tasksDir)
        let snapshotRepository = MockTaskSnapshotRepository()
        given(snapshotRepository).refresh(.value(taskID)).willReturn()
        let sut = EventStreamRepositoryImpl(toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository, scheduler: Self.defaultScheduler())

        // when
        let lease = sut.acquire(taskID)

        // then
        await verify(snapshotRepository).refresh(.value(taskID)).calledEventually(1, before: .seconds(3))
        lease.release()
    }

    @Test func givenASecondLease_whenAcquired_thenTheSnapshotIsNotRefreshedAgain() async {
        // given
        let (dir, taskID, tasksDir) = writeEventsFile(lines: [taskStartedLine()])
        defer { try? FileManager.default.removeItem(at: dir) }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(tasksDir)
        let snapshotRepository = MockTaskSnapshotRepository()
        given(snapshotRepository).refresh(.any).willReturn()
        let sut = EventStreamRepositoryImpl(toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository, scheduler: Self.defaultScheduler())

        // when
        let first = sut.acquire(taskID)
        await verify(snapshotRepository).refresh(.value(taskID)).calledEventually(1, before: .seconds(3))
        let second = sut.acquire(taskID)
        try? await Task.sleep(for: .milliseconds(50))

        // then — only the first lease triggered a refresh.
        verify(snapshotRepository).refresh(.value(taskID)).called(1)
        first.release()
        second.release()
    }

    @Test func givenEventsWritten_whenTailed_thenItemsAndEventsPublish() async {
        // given
        let (dir, taskID, tasksDir) = writeEventsFile(lines: [taskStartedLine(prompt: "build the thing")])
        defer { try? FileManager.default.removeItem(at: dir) }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(tasksDir)
        let snapshotRepository = MockTaskSnapshotRepository()
        given(snapshotRepository).refresh(.any).willReturn()
        let sut = EventStreamRepositoryImpl(toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository, scheduler: Self.defaultScheduler())

        // when
        let lease = sut.acquire(taskID)
        await waitUntil(timeout: 5) { !sut.events(for: taskID).isEmpty }

        // then
        #expect(sut.prompt(for: taskID) == "build the thing")
        #expect(!sut.items(for: taskID).isEmpty)
        lease.release()
    }

    @Test func givenAnUnknownEventKind_whenTailed_thenItStaysInEventsButNeverInItems() async {
        // given — F4-27: unknown kinds are kept for Raw events but never shown on the timeline.
        let (dir, taskID, tasksDir) = writeEventsFile(lines: [
            taskStartedLine(),
            #"{"v":1,"seq":2,"kind":"something_new_and_unrecognized"}"#
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(tasksDir)
        let snapshotRepository = MockTaskSnapshotRepository()
        given(snapshotRepository).refresh(.any).willReturn()
        let sut = EventStreamRepositoryImpl(toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository, scheduler: Self.defaultScheduler())

        // when
        let lease = sut.acquire(taskID)
        await waitUntil(timeout: 5) { sut.events(for: taskID).count >= 2 }

        // then
        #expect(sut.events(for: taskID).contains { $0.isUnknown })
        #expect(sut.items(for: taskID).allSatisfy { item in
            if case .started = item.body { return true }
            return false
        })
        lease.release()
    }

    @Test func givenALeaseReleasedTwice_whenReleased_thenTheSecondReleaseIsANoOp() async {
        // given — two leases on the same task, so a non-idempotent double release of `first` would
        // decrement the shared refcount twice and incorrectly drop `second`'s lease too. A single
        // lease can't distinguish "released once" from "released twice" — releasing it once already
        // empties `leasedTaskIDs`, so the old single-lease version of this test passed even against
        // a `release()` that always dropped the whole stream.
        let (dir, taskID, tasksDir) = writeEventsFile(lines: [taskStartedLine()])
        defer { try? FileManager.default.removeItem(at: dir) }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(tasksDir)
        let snapshotRepository = MockTaskSnapshotRepository()
        given(snapshotRepository).refresh(.any).willReturn()
        let sut = EventStreamRepositoryImpl(toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository, scheduler: Self.defaultScheduler())
        let first = sut.acquire(taskID)
        let second = sut.acquire(taskID)
        await waitUntil { sut.leasedTaskIDs.contains(taskID) }
        #expect(sut.leasedTaskIDs.contains(taskID))

        // when — `first` is released twice.
        first.release()
        first.release()

        // then — `second`'s lease survives the redundant release, and nothing crashes.
        #expect(sut.leasedTaskIDs.contains(taskID))
        second.release()
        #expect(!sut.leasedTaskIDs.contains(taskID))
    }

    @Test func givenNoLeaseHasEverBeenAcquired_whenAskedForAvailability_thenItReportsLoading() {
        // given — no stream has ever been created for this id, so there is nothing to have
        // resolved availability one way or the other yet.
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let snapshotRepository = MockTaskSnapshotRepository()
        let sut = EventStreamRepositoryImpl(toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository, scheduler: Self.defaultScheduler())

        // when / then
        #expect(sut.eventsAvailability(for: "never-leased") == .loading)
    }

    @Test func givenAnEventsFileOnDisk_whenLeased_thenAvailabilityBecomesAvailable() async {
        // given
        let (dir, taskID, tasksDir) = writeEventsFile(lines: [taskStartedLine()])
        defer { try? FileManager.default.removeItem(at: dir) }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(tasksDir)
        let snapshotRepository = MockTaskSnapshotRepository()
        given(snapshotRepository).refresh(.any).willReturn()
        let sut = EventStreamRepositoryImpl(toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository, scheduler: Self.defaultScheduler())

        // when
        let lease = sut.acquire(taskID)

        // then
        await waitUntil(timeout: 5) { sut.eventsAvailability(for: taskID) == .available }
        #expect(sut.eventsAvailability(for: taskID) == .available)
        lease.release()
    }

    @Test func givenATaskIDWithNoEventsFileEverWritten_whenLeased_thenAvailabilityBecomesUnavailable() async {
        // given — a well-formed but never-written path, so the tailer's reads all fail to open it.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PbRepoTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let taskID = "evt-" + UUID().uuidString.prefix(8)
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(dir.path)
        let snapshotRepository = MockTaskSnapshotRepository()
        given(snapshotRepository).refresh(.any).willReturn()
        let sut = EventStreamRepositoryImpl(toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository, scheduler: Self.defaultScheduler())

        // when
        let lease = sut.acquire(String(taskID))

        // then
        await waitUntil(timeout: 5) { sut.eventsAvailability(for: String(taskID)) == .unavailable }
        #expect(sut.eventsAvailability(for: String(taskID)) == .unavailable)
        lease.release()
    }

    @Test func givenTwoLeases_whenOnlyOneIsReleased_thenTheTaskStaysLeased() async {
        // given
        let (dir, taskID, tasksDir) = writeEventsFile(lines: [taskStartedLine()])
        defer { try? FileManager.default.removeItem(at: dir) }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(tasksDir)
        let snapshotRepository = MockTaskSnapshotRepository()
        given(snapshotRepository).refresh(.any).willReturn()
        let sut = EventStreamRepositoryImpl(toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository, scheduler: Self.defaultScheduler())
        let first = sut.acquire(taskID)
        let second = sut.acquire(taskID)
        await waitUntil { sut.leasedTaskIDs.contains(taskID) }

        // when
        first.release()

        // then
        #expect(sut.leasedTaskIDs.contains(taskID))
        second.release()
        #expect(!sut.leasedTaskIDs.contains(taskID))
    }

    // MARK: - Coalescing (Monitor piece 8, Review round 1 item 4)

    private func deltaLine(seq: Int, messageID: String = "m1", blockIndex: Int = 0, text: String) -> String {
        #"{"v":1,"seq":\#(seq),"kind":"assistant_delta","message_id":"\#(messageID)","block_index":\#(blockIndex),"text":"\#(text)"}"#
    }

    private func finishedLine(seq: Int) -> String {
        #"{"v":1,"seq":\#(seq),"kind":"task_finished","status":"completed","exit_code":0}"#
    }

    private func appendLine(_ line: String, to path: URL) {
        guard let handle = try? FileHandle(forWritingTo: path) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    /// A scheduler whose `schedule(after:execute:)` work item is captured (never invoked) rather
    /// than run, so the test controls exactly when the coalescing window "fires" — the same
    /// capture-and-invoke pattern `TaskListRepositoryImplTests+SafetyPoll.swift` uses for the 10 s
    /// poll. `callCount` distinguishes "scheduled once, more deltas piggy-backed on it" from a bug
    /// that would (wrongly) schedule a fresh flush per delta.
    private func makeFlushCapturingScheduler() -> (
        scheduler: MockScheduling, capturedFlush: LockedBox<(@Sendable () -> Void)?>, callCount: LockedBox<Int>
    ) {
        let scheduler = MockScheduling()
        let capturedFlush = LockedBox<(@Sendable () -> Void)?>(nil)
        let callCount = LockedBox(0)
        given(scheduler).now().willReturn(Date())
        given(scheduler).scheduleRepeating(every: .any, execute: .any).willReturn(AnyCancellable {})
        given(scheduler).schedule(after: .any, execute: .any).willProduce { _, work in
            callCount.mutate { $0 += 1 }
            capturedFlush.mutate { $0 = work }
            return AnyCancellable {}
        }
        return (scheduler, capturedFlush, callCount)
    }

    @Test func givenABurstOfPureDeltaChunks_whenBuffered_thenTheTimelineIsNotRebuiltUntilTheWindowFires() async {
        // given
        let (dir, taskID, tasksDir) = writeEventsFile(lines: [taskStartedLine()])
        defer { try? FileManager.default.removeItem(at: dir) }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(tasksDir)
        let snapshotRepository = MockTaskSnapshotRepository()
        given(snapshotRepository).refresh(.any).willReturn()
        let (scheduler, capturedFlush, callCount) = makeFlushCapturingScheduler()
        let sut = EventStreamRepositoryImpl(toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository, scheduler: scheduler)
        let lease = sut.acquire(taskID)
        await waitUntil(timeout: 5) { !sut.items(for: taskID).isEmpty }
        let eventsPath = dir.appendingPathComponent("\(taskID).events.jsonl")

        // when — two delta chunks for the same block, written as two separate appends so the
        // tailer is very likely to observe them as two separate callbacks.
        appendLine(deltaLine(seq: 2, text: "ALPHA"), to: eventsPath)
        await waitUntil(timeout: 5) { capturedFlush.value != nil }

        // then — scheduled, but not yet applied: no `.text` item exists yet.
        #expect(!sut.items(for: taskID).contains { if case .text = $0.body { return true }; return false })

        appendLine(deltaLine(seq: 3, text: "BETA"), to: eventsPath)
        // A second pure-delta callback while a flush is already scheduled must not schedule a
        // second one — it piggy-backs on the pending flush instead (the whole point of coalescing).
        // Nothing observable changes while it stays buffered, so — as in
        // `TaskListRepositoryImplTests+SafetyPoll.swift`'s `whenNoConditionHolds` negative check —
        // this gives any (wrongly) triggered second schedule a bounded chance to happen before
        // asserting it did not, rather than polling for a condition that must never become true.
        try? await Task.sleep(for: .milliseconds(500))
        #expect(callCount.value == 1, "a second delta while a flush is already pending must not re-schedule")

        // when — the coalescing window "fires".
        capturedFlush.value?()

        // then — one rebuild reflects both chunks, merged into a single in-progress item.
        let items = sut.items(for: taskID)
        guard case .text(let text, let streaming) = items.last?.body else { Issue.record("expected a text item, got \(items)"); return }
        #expect(text == "ALPHABETA")
        #expect(streaming)
        lease.release()
    }

    @Test func givenATaskFinishedEventArrivesWhileDeltasAreBuffered_whenEnqueued_thenEverythingFlushesImmediately() async {
        // given
        let (dir, taskID, tasksDir) = writeEventsFile(lines: [taskStartedLine()])
        defer { try? FileManager.default.removeItem(at: dir) }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(tasksDir)
        let snapshotRepository = MockTaskSnapshotRepository()
        given(snapshotRepository).refresh(.any).willReturn()
        let (scheduler, capturedFlush, _) = makeFlushCapturingScheduler()
        let sut = EventStreamRepositoryImpl(toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository, scheduler: scheduler)
        let lease = sut.acquire(taskID)
        await waitUntil(timeout: 5) { !sut.items(for: taskID).isEmpty }
        let eventsPath = dir.appendingPathComponent("\(taskID).events.jsonl")

        // when — a delta is buffered (scheduled, not yet applied), then the task finishes.
        appendLine(deltaLine(seq: 2, text: "ALPHA"), to: eventsPath)
        await waitUntil(timeout: 5) { capturedFlush.value != nil }
        appendLine(finishedLine(seq: 3), to: eventsPath)

        // then — both the buffered delta and the finish are visible without ever firing the
        // captured (still-pending) flush closure — "final flush on terminal".
        await waitUntil(timeout: 5) {
            sut.items(for: taskID).contains { if case .finished = $0.body { return true }; return false }
        }
        let items = sut.items(for: taskID)
        #expect(items.contains { if case .text(let text, _) = $0.body { return text == "ALPHA" }; return false })
        #expect(items.contains { if case .finished = $0.body { return true }; return false })
        lease.release()
    }

    @Test func givenAResetArrivesWhileADeltaIsBuffered_whenFlushed_thenTheResetWinsAndOrderingIsPreserved() async {
        // given — F4-27-style reset: same inode, truncated and rewritten to at least its old size,
        // so `LineTail` reports it as a reset (`EventsTests.swift`'s
        // `givenASameInodeTruncateAndRegrow_whenRead_thenItIsDetectedAsAReset` proves the detection
        // itself; this proves the repository replays it in the right order relative to what was
        // already buffered ahead of it).
        let (dir, taskID, tasksDir) = writeEventsFile(lines: [taskStartedLine(prompt: "first")])
        defer { try? FileManager.default.removeItem(at: dir) }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(tasksDir)
        let snapshotRepository = MockTaskSnapshotRepository()
        given(snapshotRepository).refresh(.any).willReturn()
        let (scheduler, capturedFlush, _) = makeFlushCapturingScheduler()
        let sut = EventStreamRepositoryImpl(toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository, scheduler: scheduler)
        let lease = sut.acquire(taskID)
        await waitUntil(timeout: 5) { !sut.items(for: taskID).isEmpty }
        let eventsPath = dir.appendingPathComponent("\(taskID).events.jsonl")

        // when — a delta is buffered (scheduled, not yet applied)...
        appendLine(deltaLine(seq: 2, text: "STALE"), to: eventsPath)
        await waitUntil(timeout: 5) { capturedFlush.value != nil }

        // ...then the file is truncated and rewritten (same inode, regrown past the old offset) with
        // entirely fresh content, which the repository must apply AFTER the already-buffered delta —
        // dropping "STALE" — not before it.
        let handle = try? FileHandle(forWritingTo: eventsPath)
        try? handle?.truncate(atOffset: 0)
        try? handle?.write(contentsOf: Data((taskStartedLine(prompt: "second") + "\n" + deltaLine(seq: 1, messageID: "m2", text: "FRESH") + "\n").utf8))
        try? handle?.close()

        // then — flushed immediately (a reset is never a pure-delta burst), reflecting only the
        // fresh content.
        await waitUntil(timeout: 5) { sut.prompt(for: taskID) == "second" }
        let items = sut.items(for: taskID)
        #expect(!items.contains { if case .text(let text, _) = $0.body { return text.contains("STALE") }; return false })
        #expect(items.contains { if case .text(let text, _) = $0.body { return text == "FRESH" }; return false })
        lease.release()
    }

    @Test func givenSeveralRealFlushesOverTime_whenComparedToAOneShotRebuild_thenTheIncrementallyBuiltItemsAreIdentical() async {
        // given — Codex review round 1, finding 1: `EventStreamRepositoryImpl` now keeps one
        // `TimelineBuilder` per task, appending only each flush's own new events rather than
        // rebuilding via `Timeline.items(from: allEvents)` every time. This proves that incremental
        // path stays correct across SEVERAL real flushes (not just one), by checking it against a
        // fresh one-shot build of the whole accumulated history at the end — the strongest available
        // guarantee that "incremental" never quietly means "different".
        let (dir, taskID, tasksDir) = writeEventsFile(lines: [taskStartedLine(prompt: "multi-flush")])
        defer { try? FileManager.default.removeItem(at: dir) }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(tasksDir)
        let snapshotRepository = MockTaskSnapshotRepository()
        given(snapshotRepository).refresh(.any).willReturn()
        let sut = EventStreamRepositoryImpl(toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository, scheduler: Self.defaultScheduler())
        let lease = sut.acquire(taskID)
        await waitUntil(timeout: 5) { !sut.items(for: taskID).isEmpty }
        let eventsPath = dir.appendingPathComponent("\(taskID).events.jsonl")

        // when — several distinct, non-delta writes, each its own immediate flush (a notice is never
        // a pure-delta burst, so nothing here depends on the coalescing timer).
        for round in 0 ..< 5 {
            appendLine(#"{"v":1,"seq":\#(round + 2),"kind":"notice","text":"n\#(round)"}"#, to: eventsPath)
            await waitUntil(timeout: 5) { sut.events(for: taskID).count == round + 2 }
        }

        // then — the incrementally-built `items` match a fresh one-shot rebuild of the complete
        // accumulated raw events at this point.
        let incremental = sut.items(for: taskID)
        let oneShot = Timeline.items(from: sut.events(for: taskID))
        #expect(incremental == oneShot)
        #expect(incremental.count == 6, "task_started plus 5 notices")
        lease.release()
    }
}
