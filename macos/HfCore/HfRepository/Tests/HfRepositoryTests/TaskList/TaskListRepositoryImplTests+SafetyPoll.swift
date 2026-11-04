import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
import Testing

extension TaskListRepositoryImplTests {

    // MARK: Public polling

    /// Captures the one-second tick and reads a controllable clock without real timers.
    private func makePollCapturingScheduler(now: LockedBox<Date>) -> (scheduler: MockScheduling, capturedPoll: LockedBox<(@Sendable () -> Void)?>) {
        let scheduler = MockScheduling()
        let capturedPoll = LockedBox<(@Sendable () -> Void)?>(nil)
        given(scheduler).now().willProduce { now.value }
        given(scheduler).schedule(after: .any, execute: .any).willReturn(AnyCancellable {})
        given(scheduler).scheduleRepeating(every: .value(1), execute: .any).willProduce { _, work in
            capturedPoll.mutate { $0 = work }
            return AnyCancellable {}
        }
        return (scheduler, capturedPoll)
    }

    private func countingCtl(_ result: @escaping @Sendable () -> String) -> (client: CtlClient, callCount: LockedBox<Int>) {
        let callCount = LockedBox(0)
        let runner = compatibleRunner { _ in
            callCount.mutate { $0 += 1 }
            return .success(historyStdout(result()))
        }
        return (CtlClient(executable: "/bin/echo", environment: [:], runner: runner), callCount)
    }

    @Test func givenVisibleIdle_whenNextTickArrives_thenItRefreshes() async {
        let now = LockedBox(Date())
        let (scheduler, capturedPoll) = makePollCapturingScheduler(now: now)
        let (client, callCount) = countingCtl { #"{"v":2,"tasks":[]}"# }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn("/unused/tasks")
        given(toolEnvironment).ctl().willReturn(.success(client))
        let sut = makeSUT(toolEnvironment: toolEnvironment, scheduler: scheduler)
        sut.start()
        await waitUntil { sut.hasListed }
        await waitUntil { capturedPoll.value != nil }
        #expect(capturedPoll.value != nil)
        let callsAfterStart = callCount.value

        now.mutate { $0 = $0.addingTimeInterval(1) }
        capturedPoll.value?()

        await waitUntil(timeout: 3) { callCount.value > callsAfterStart }
        #expect(callCount.value > callsAfterStart)
        withExtendedLifetime(sut) {}
    }

    @Test(arguments: ["running", "failed"])
    func givenTheSafetyPollFires_whenTaskIsRunningOrNeedsReconciliation_thenItRefreshes(status: String) async {
        let now = LockedBox(Date())
        let (scheduler, capturedPoll) = makePollCapturingScheduler(now: now)
        let (client, callCount) = countingCtl { #"{"v":2,"tasks":[{"task_id":"a","status":"\#(status)","needs_reconciliation":true,"backend":"claude"}]}"# }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn("/unused/tasks")
        given(toolEnvironment).ctl().willReturn(.success(client))
        let sut = makeSUT(toolEnvironment: toolEnvironment, scheduler: scheduler)
        sut.start()
        await waitUntil { sut.hasListed }
        #expect(sut.tasks.contains { $0.status.isRunning || $0.raw["needs_reconciliation"]?.boolValue == true })
        await waitUntil { capturedPoll.value != nil }
        #expect(capturedPoll.value != nil)
        let callsAfterStart = callCount.value

        capturedPoll.value?()

        await waitUntil(timeout: 3) { callCount.value > callsAfterStart }
        #expect(callCount.value > callsAfterStart)
        withExtendedLifetime(sut) {}
    }

    @Test func givenColdHistoryBootstrap_whenSafetyPollFires_thenItAdvancesWithoutActiveTasks() async {
        let (scheduler, capturedPoll) = makePollCapturingScheduler(now: LockedBox(Date()))
        let calls = LockedBox(0)
        let bootstrapResponse = #"{"product":"harflow","format":"harflow.ctl","v":1,"product_version":"0.0.1","#
            + #""result":{"items":[],"next_cursor":null,"has_more":false,"bootstrap_pending":true}}"#
        #expect(JSONValue.parse(Data(bootstrapResponse.utf8)) != nil)
        let runner = compatibleRunner { _ in
            calls.mutate { $0 += 1 }
            return .success(stdout(bootstrapResponse))
        }
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn("/unused/tasks")
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = makeSUT(toolEnvironment: environment, scheduler: scheduler)
        sut.start()
        await waitUntil { capturedPoll.value != nil && sut.historyState.bootstrapPending }
        let initial = calls.value
        capturedPoll.value?()
        await waitUntil { calls.value > initial }
        #expect(calls.value > initial)
        #expect(sut.tasks.isEmpty)
        withExtendedLifetime(sut) {}
    }

    @Test func givenTheSafetyPollFires_whenThereIsAListError_thenItRefreshes() async {
        let now = LockedBox(Date())
        let (scheduler, capturedPoll) = makePollCapturingScheduler(now: now)
        let failed = LockedBox(false)
        let (client, callCount) = countingCtl {
            failed.value
                ? #"{"v":2,"error":{"code":"session_busy","message":"boom"}}"#
                : #"{"v":2,"tasks":[]}"#
        }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn("/unused/tasks")
        given(toolEnvironment).ctl().willReturn(.success(client))
        let sut = makeSUT(toolEnvironment: toolEnvironment, scheduler: scheduler)
        sut.start()
        await waitUntil { sut.hasListed }
        await waitUntil { capturedPoll.value != nil }
        #expect(capturedPoll.value != nil)
        failed.mutate { $0 = true }
        await sut.refresh()
        await waitUntil { sut.listError != nil }
        let callsAfterError = callCount.value

        capturedPoll.value?()

        await waitUntil(timeout: 3) { callCount.value > callsAfterError }
        #expect(callCount.value > callsAfterError)
        withExtendedLifetime(sut) {}
    }

    @Test func givenNoTaskDirectory_whenVisiblePollFires_thenPublicListingStillRefreshes() async {
        let missingDir = FileManager.default.temporaryDirectory.appendingPathComponent("HfRepoTests-missing-\(UUID().uuidString)").path
        let now = LockedBox(Date())
        let (scheduler, capturedPoll) = makePollCapturingScheduler(now: now)
        let (client, callCount) = countingCtl { #"{"v":2,"tasks":[]}"# }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(missingDir)
        given(toolEnvironment).ctl().willReturn(.success(client))
        let sut = makeSUT(toolEnvironment: toolEnvironment, scheduler: scheduler)
        sut.start()
        await waitUntil { sut.hasListed }
        await waitUntil { capturedPoll.value != nil }
        #expect(capturedPoll.value != nil)
        let callsAfterStart = callCount.value

        capturedPoll.value?()

        await waitUntil(timeout: 3) { callCount.value > callsAfterStart }
        #expect(callCount.value > callsAfterStart)
        withExtendedLifetime(sut) {}
    }

    @Test func givenVisibleIdleCatalog_whenExternalTaskAppears_thenNextTickDiscoversIt() async {
        // given
        let listing = LockedBox(#"{"v":2,"tasks":[]}"#)
        let (scheduler, tick) = makePollCapturingScheduler(now: LockedBox(Date()))
        let (client, _) = countingCtl { listing.value }
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn("/unused/tasks")
        given(environment).ctl().willReturn(.success(client))
        let sut = makeSUT(toolEnvironment: environment, scheduler: scheduler)
        sut.start()
        await waitUntil { sut.hasListed && tick.value != nil }
        #expect(sut.tasks.isEmpty)
        // when
        listing.mutate { $0 = #"{"v":2,"tasks":[{"task_id":"external","status":"completed","backend":"claude"}]}"# }
        tick.value?()
        // then
        await waitUntil { sut.tasks.map(\.taskID) == ["external"] }
        #expect(sut.tasks.map(\.taskID) == ["external"])
        withExtendedLifetime(sut) {}
    }

    @Test func givenHeldPollRead_whenManyPollsArrive_thenOnlyOnePassRunsWithoutFollowup() async {
        // given
        let gate = AsyncGate()
        let reads = LockedBox(0)
        let runner = compatibleRunner { _ in
            reads.mutate { $0 += 1 }
            if reads.value == 1 { gate.waitSync() }
            return .success(historyStdout(#"{"v":2,"tasks":[]}"#))
        }
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn("/unused/tasks")
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = makeSUT(toolEnvironment: environment)
        let poll = Task { await sut.evaluateSafetyPoll() }
        await waitUntil { reads.value == 1 }
        // when
        for _ in 0 ..< 100 { await sut.evaluateSafetyPoll() }
        #expect(reads.value == 1)
        gate.open()
        await poll.value
        // then — exactly history and active reconciliation, with no followup pass.
        #expect(reads.value == 2)
        #expect(sut.safetyPollEvaluationCount == 101)
    }

    @Test func givenDuplicateStart_whenInitialListingCompletes_thenOnlyOneObservationIsInstalled() async {
        // given
        let source = CapturedTaskListInvalidationSource()
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn("/unused/tasks")
        given(environment).ctl().willReturn(.success(ctlClient(listing: [])))
        let sut = makeSUT(toolEnvironment: environment, invalidationSource: source)
        // when
        sut.start()
        sut.start()
        await waitUntil { source.observations.value == 1 }
        // then
        #expect(source.observations.value == 1)
        verify(environment).discoverEnvironment().called(1)
        withExtendedLifetime(sut) {}
    }

    @Test func givenSourceInvalidatesSynchronously_whenObservationStarts_thenStartupDoesNotDeadlockOrDuplicateObserver() async {
        // given
        let source = CapturedTaskListInvalidationSource(invalidateOnObserve: true)
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn("/unused/tasks")
        given(environment).ctl().willReturn(.success(ctlClient(listing: [])))
        let sut = makeSUT(toolEnvironment: environment, invalidationSource: source)
        // when
        sut.start()
        // then
        await waitUntil { source.observations.value == 1 && sut.safetyPollEvaluationCount >= 1 }
        #expect(source.observations.value == 1)
        #expect(sut.safetyPollEvaluationCount >= 1)
        withExtendedLifetime(sut) {}
    }

    @Test func givenRuntimeChanges_whenCancelledOldObserverCallsBack_thenItCannotReadOrReinstall() async {
        // given
        let source = CapturedTaskListInvalidationSource()
        let (client, reads) = countingCtl { #"{"v":2,"tasks":[]}"# }
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn("/unused/tasks")
        given(environment).ctl().willReturn(.success(client))
        let sut = makeSUT(toolEnvironment: environment, invalidationSource: source)
        sut.start()
        await waitUntil { source.observations.value == 1 }
        let oldCallback = source.callback.value
        // when
        sut.settingsChanged()
        await waitUntil { source.observations.value == 2 }
        let before = reads.value
        oldCallback?()
        // then — stale generation is rejected synchronously before enqueueing work.
        #expect(reads.value == before)
        #expect(source.observations.value == 2)
        #expect(source.cancellations.value == 1)
        withExtendedLifetime(sut) {}
    }

    @Test func givenDisposedRepository_whenOldCallbackFires_thenItCannotReadOrResubscribe() async {
        // given
        let source = CapturedTaskListInvalidationSource()
        let (client, reads) = countingCtl { #"{"v":2,"tasks":[]}"# }
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn("/unused/tasks")
        given(environment).ctl().willReturn(.success(client))
        var sut: TaskListRepositoryImpl? = makeSUT(toolEnvironment: environment, invalidationSource: source)
        let released = WeakTaskListRepository(sut)
        sut?.start()
        await waitUntil { source.observations.value == 1 }
        let before = reads.value
        // when
        sut = nil
        await waitUntil { released.value == nil && source.cancellations.value == 1 }
        source.callback.value?()
        // then — callback owns only a weak repository reference.
        #expect(released.value == nil)
        #expect(reads.value == before)
        #expect(source.observations.value == 1)
        #expect(source.cancellations.value == 1)
    }

    @Test func givenPrestartPreparationRetry_whenRuntimeChanges_thenRetainedOldRetryCannotRead() async {
        // given
        let scheduler = MockScheduling()
        let retry = LockedBox<(@Sendable () -> Void)?>(nil)
        given(scheduler).now().willReturn(Date())
        given(scheduler).scheduleRepeating(every: .any, execute: .any).willReturn(AnyCancellable {})
        given(scheduler).schedule(after: .any, execute: .any).willProduce { _, callback in
            retry.mutate { $0 = callback }
            return AnyCancellable {}
        }
        let preparing = LockedBox(true)
        let reads = LockedBox(0)
        let runner = compatibleRunner { _ in
            reads.mutate { $0 += 1 }
            let pending = preparing.value ? "true" : "false"
            return .success(stdout(
                #"{"product":"harflow","format":"harflow.ctl","v":1,"product_version":"0.0.1","#
                    + #""result":{"items":[],"next_cursor":null,"has_more":false,"bootstrap_pending":\#(pending)}}"#
            ))
        }
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn("/unused/tasks")
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = makeSUT(toolEnvironment: environment, scheduler: scheduler)
        await sut.refresh()
        let oldRetry = retry.value
        #expect(oldRetry != nil)
        // when
        preparing.mutate { $0 = false }
        sut.settingsChanged()
        _ = await sut.refreshAndWait()
        let before = reads.value
        oldRetry?()
        // then — the cancelled timer keeps its original generation.
        #expect(reads.value == before)
        withExtendedLifetime(sut) {}
    }

    // MARK: MS-LIST-5 — titles

    @Test func givenReadableLogsWithoutCatalogTitles_whenRefreshed_thenNoEventLogTitleLoadStarts() async {
        // given
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HfRepoTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try? (currentEventFixture(#"{"v":1,"seq":1,"kind":"task_started","prompt":"log title"}"#) + "\n")
            .write(to: dir.appendingPathComponent("t1.events.jsonl"), atomically: true, encoding: .utf8)
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(dir.path)
        given(environment).ctl().willReturn(.success(ctlClient(listing: ["t1"])))
        let sut = makeSUT(toolEnvironment: environment)
        // when
        await sut.refresh()
        // then
        #expect(sut.titleLoadPassCount == 0)
        #expect(sut.title("t1") == "Task t1")
    }

    @Test func givenNoTitleFound_whenDisplayed_thenTheFallbackIsTaskPlusFirst8Chars() {
        // given
        let sut = makeSUT()
        // when / then
        #expect(sut.title("abcdefgh12345") == "Task abcdefgh")
    }

    // MARK: MS-LIST-6 — detail() precedence (the C.8 fix)

    @Test func givenAListingAndASnapshotWithDifferentStatuses_whenAskedForDetail_thenTheListingStatusWins() async {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        given(toolEnvironment).ctl().willReturn(.success(ctlClient(listing: ["t1"])))
        let snapshotRepository = MockTaskSnapshotRepository()
        given(snapshotRepository).evict(keeping: .any).willReturn()
        given(snapshotRepository).refresh(.any).willReturn()
        given(snapshotRepository).snapshot(.value("t1")).willReturn(makeTaskInfo("t1", status: "completed"))
        let sut = makeSUT(toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository)
        await sut.refresh()

        // when
        let detail = sut.detail("t1")

        // then — the listing entry (status "running") wins over the snapshot's "completed".
        #expect(detail?.status == .running)
    }

    @Test func givenTaskOutsideNewestPage_whenAskedForDetail_thenLoadedHistoryRemainsAvailable() async {
        // given — seed a listing containing "t1" first and confirm `detail` actually resolves it,
        // then list again without it. `ctl()` reads from a mutable box rather than being re-`given`
        // between calls — see the note on the `Mockable` FIFO pitfall elsewhere in this file.
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let resultBox = LockedBox<Result<CtlClient, ToolError>>(.success(ctlClient(listing: ["t1"])))
        given(toolEnvironment).ctl().willProduce { resultBox.value }
        let sut = makeSUT(toolEnvironment: toolEnvironment)
        await sut.refresh()
        #expect(sut.detail("t1") != nil)

        // when — "t1" drops out of the listing entirely.
        resultBox.mutate { $0 = .success(ctlClient(listing: [])) }
        await sut.refresh()
        let detail = sut.detail("t1")

        // then
        #expect(detail?.taskID == "t1")
    }

    @Test func givenNoSnapshotAndNoDifferingStatus_whenAskedForDetail_thenTheListingEntryIsReturned() async {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        given(toolEnvironment).ctl().willReturn(.success(ctlClient(listing: ["t1"])))
        let sut = makeSUT(toolEnvironment: toolEnvironment)
        await sut.refresh()

        // when
        let detail = sut.detail("t1")

        // then
        #expect(detail?.taskID == "t1")
    }

    // MARK: MS-LIST-7 — connectionLine

    @Test func givenEachListErrorShape_whenReadingTheConnectionLine_thenTheTextDistinguishesEachCase() async {
        // given: never listed.
        let notYetListed = makeSUT()
        #expect(notYetListed.connectionLine == "connecting…")

        // given: not found.
        let toolEnvironmentNotFound = MockToolEnvironmentRepository()
        given(toolEnvironmentNotFound).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        given(toolEnvironmentNotFound).ctl().willReturn(.failure(.notFound(tool: "harflow-ctl", searched: [])))
        let notFoundSUT = makeSUT(toolEnvironment: toolEnvironmentNotFound)
        await notFoundSUT.refresh()
        #expect(notFoundSUT.connectionLine == "harflow-ctl not found")

        // given: some other failure.
        let toolEnvironmentUnreadable = MockToolEnvironmentRepository()
        given(toolEnvironmentUnreadable).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        given(toolEnvironmentUnreadable).ctl().willReturn(.failure(.unreadable(tool: "harflow-ctl", exitCode: 1, stderr: "boom")))
        let unreadableSUT = makeSUT(toolEnvironment: toolEnvironmentUnreadable)
        await unreadableSUT.refresh()
        #expect(unreadableSUT.connectionLine == "harflow not readable")

        // given: connected, with backends.
        let toolEnvironmentConnected = MockToolEnvironmentRepository()
        given(toolEnvironmentConnected).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        given(toolEnvironmentConnected).ctl().willReturn(.success(ctlClient(listing: ["a"])))
        let connectedSUT = makeSUT(toolEnvironment: toolEnvironmentConnected)
        await connectedSUT.refresh()
        #expect(connectedSUT.connectionLine == "harflow connected · claude")
    }

    // MARK: F4-08 — the first listing never notifies

    @Test func givenTheFirstListing_whenItCompletes_thenNothingIsNotified() async {
        // given — a root that would look "finished" if judged in isolation, but there is no
        // "previous" listing to compare against yet.
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        given(toolEnvironment).ctl().willReturn(.success(ctlClient(listing: ["a"])))
        let finishNotifier = MockFinishNotifier()
        let notifyCallCount = LockedBox(0)
        given(finishNotifier).notify(.any, titleFor: .any).willProduce { _, _ in notifyCallCount.mutate { $0 += 1 } }
        let sut = makeSUT(toolEnvironment: toolEnvironment, finishNotifier: finishNotifier)

        // when
        await sut.refresh()

        // then — the listing was really applied (rules out a no-op refresh that would trivially
        // never notify anything)...
        #expect(sut.hasListed)
        #expect(sut.tasks.map(\.taskID) == ["a"])
        // ...and still nothing was notified, because there is no "previous" listing to compare
        // against yet.
        #expect(notifyCallCount.value == 0)
    }

    @Test func givenASecondListingWithARootNowFinished_whenItCompletes_thenItIsNotified() async {
        // given — F4-08: the first listing sees "a" running; the second sees it terminal, which is
        // exactly `Lineage.finishedRoots`'s definition of something worth notifying about.
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let resultBox = LockedBox<Result<CtlClient, ToolError>>(.success(ctlClient(listing: ["a"])))
        given(toolEnvironment).ctl().willProduce { resultBox.value }
        let finishNotifier = MockFinishNotifier()
        let notified = LockedBox<[TaskInfo]>([])
        given(finishNotifier).notify(.any, titleFor: .any).willProduce { finished, _ in notified.mutate { $0 = finished } }
        let sut = makeSUT(toolEnvironment: toolEnvironment, finishNotifier: finishNotifier)
        await sut.refresh()
        #expect(notified.value.isEmpty)

        // when
        let doneRunner = StubProcessRunner(output: historyStdout(#"{"v":2,"tasks":[{"task_id":"a","status":"completed","backend":"claude","depth":0}]}"#))
        resultBox.mutate { $0 = .success(CtlClient(executable: "/bin/echo", environment: [:], runner: PositiveCtlRunner(doneRunner))) }
        await sut.refresh()

        // then
        #expect(notified.value.map(\.taskID) == ["a"])
    }

    // MARK: runningInSubtrees

    @Test func givenARunningSubTask_whenCountingRunningSubtrees_thenItIsIncluded() async {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let runner = StubProcessRunner(output: historyStdout(
            #"{"v":2,"tasks":[{"task_id":"root","status":"completed","backend":"claude","depth":0},"#
                + #"{"task_id":"child","status":"running","backend":"claude","spawned_by":"root","depth":1}]}"#
        ))
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: PositiveCtlRunner(runner))))
        let sut = makeSUT(toolEnvironment: toolEnvironment)
        await sut.refresh()

        // when
        let running = sut.runningInSubtrees(of: ["root"])

        // then
        #expect(running == ["child"])
    }

    // MARK: start()

    @Test func givenStartCalledTwice_whenObserved_thenDiscoveryOnlyRunsOnce() async {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn("/unused/tasks")
        given(toolEnvironment).ctl().willReturn(.success(ctlClient(listing: [])))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when
        sut.start()
        sut.start()
        await waitUntil { sut.hasListed }
        // No further wait needed, fixed or otherwise: `start()`'s `started` guard is checked and set
        // synchronously, under `startLock`, before either call returns — so by the time both calls
        // above have returned, whether a second discovery Task was spawned is already decided. And
        // `start()`'s own Task awaits `discoverEnvironment()` before calling `refresh()`, which is
        // what eventually sets `hasListed` — so once `hasListed` is true, the one discovery call has
        // already been recorded.

        // then
        verify(toolEnvironment).discoverEnvironment().called(1)
    }

    @Test func givenToolDirectoryChanges_whenSettingsChangedIsCalled_thenARefreshFires() async {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        given(toolEnvironment).ctl().willReturn(.success(ctlClient(listing: ["x"])))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when
        sut.settingsChanged()

        // then
        await waitUntil { sut.hasListed }
        #expect(sut.tasks.map(\.taskID) == ["x"])
    }
}

private final class CapturedTaskListInvalidationSource: TaskListInvalidationSource, @unchecked Sendable {
    let observations = LockedBox(0)
    let cancellations = LockedBox(0)
    let callback = LockedBox<(@Sendable () -> Void)?>(nil)
    let invalidateOnObserve: Bool

    init(invalidateOnObserve: Bool = false) { self.invalidateOnObserve = invalidateOnObserve }

    func observe(isUrgent: @escaping @Sendable () -> Bool,
                 onInvalidated: @escaping @Sendable () -> Void) -> AnyCancellable {
        observations.mutate { $0 += 1 }
        callback.mutate { $0 = onInvalidated }
        if invalidateOnObserve { onInvalidated() }
        return AnyCancellable { [cancellations] in cancellations.mutate { $0 += 1 } }
    }
}

private final class WeakTaskListRepository: @unchecked Sendable {
    weak var value: TaskListRepositoryImpl?
    init(_ value: TaskListRepositoryImpl?) { self.value = value }
}
