import Combine
import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
import PbTestUtilities
import Testing

extension TaskListRepositoryImplTests {

    // MARK: MS-LIST-3/F4-06 — the 10 s safety poll's four refresh conditions

    /// Builds a scheduler whose `scheduleRepeating(every: 10, …)` work item is captured (so the test
    /// can fire it directly, with no real timer) and whose `now()` reads a controllable box — the
    /// same capture-and-invoke pattern as the throttle test, extended to a *stateful* `now()` so the
    /// reconcile-interval math can be driven without sleeping. Built outside `makeSUT`'s default
    /// scheduler for the reason documented on `defaultScheduler()`.
    private func makePollCapturingScheduler(now: LockedBox<Date>) -> (scheduler: MockScheduling, capturedPoll: LockedBox<(@Sendable () -> Void)?>) {
        let scheduler = MockScheduling()
        let capturedPoll = LockedBox<(@Sendable () -> Void)?>(nil)
        given(scheduler).now().willProduce { now.value }
        given(scheduler).schedule(after: .any, execute: .any).willReturn(AnyCancellable {})
        given(scheduler).scheduleRepeating(every: .value(10), execute: .any).willProduce { _, work in
            capturedPoll.mutate { $0 = work }
            return AnyCancellable {}
        }
        return (scheduler, capturedPoll)
    }

    private func countingCtl(_ result: @escaping @Sendable () -> String) -> (client: CtlClient, callCount: LockedBox<Int>) {
        let callCount = LockedBox(0)
        let runner = StubProcessRunner { _ in
            callCount.mutate { $0 += 1 }
            return .success(stdout(result()))
        }
        return (CtlClient(executable: "/bin/echo", environment: [:], runner: runner), callCount)
    }

    @Test func givenTheSafetyPollFires_whenTheReconcileIntervalHasElapsed_thenItRefreshes() async {
        // given
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PbRepoTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = LockedBox(Date())
        let (scheduler, capturedPoll) = makePollCapturingScheduler(now: now)
        let (client, callCount) = countingCtl { #"{"v":2,"tasks":[]}"# }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(dir.path)
        given(toolEnvironment).ctl().willReturn(.success(client))
        let sut = makeSUT(toolEnvironment: toolEnvironment, scheduler: scheduler)
        sut.start()
        await waitUntil { sut.hasListed }
        // `hasListed` becomes true inside `refresh()`, before `startWatching()` has run and called
        // `scheduleRepeating` — waiting for `capturedPoll` to actually be set avoids firing a `nil`
        // closure that would silently no-op.
        await waitUntil { capturedPoll.value != nil }
        #expect(capturedPoll.value != nil)
        let callsAfterStart = callCount.value

        // when — no task is running, there is no list error, and the watcher is attached (the
        // folder exists), so only the elapsed-reconcile-interval condition can explain a refresh.
        now.mutate { $0 = $0.addingTimeInterval(RefreshTrigger.reconcileInterval + 1) }
        capturedPoll.value?()

        // then
        await waitUntil(timeout: 3) { callCount.value > callsAfterStart }
        #expect(callCount.value > callsAfterStart)
        withExtendedLifetime(sut) {}
    }

    @Test func givenTheSafetyPollFires_whenATaskIsRunning_thenItRefreshes() async {
        // given — "now" never advances, so the reconcile interval never elapses; only "any task
        // running" can explain the refresh below.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PbRepoTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = LockedBox(Date())
        let (scheduler, capturedPoll) = makePollCapturingScheduler(now: now)
        let (client, callCount) = countingCtl { #"{"v":2,"tasks":[{"task_id":"a","status":"running","backend":"claude"}]}"# }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(dir.path)
        given(toolEnvironment).ctl().willReturn(.success(client))
        let sut = makeSUT(toolEnvironment: toolEnvironment, scheduler: scheduler)
        sut.start()
        await waitUntil { sut.hasListed }
        #expect(sut.tasks.contains { $0.status.isRunning })
        // See the note in `whenTheReconcileIntervalHasElapsed_thenItRefreshes` on why the captured
        // poll closure must be waited for before firing it.
        await waitUntil { capturedPoll.value != nil }
        #expect(capturedPoll.value != nil)
        let callsAfterStart = callCount.value

        // when
        capturedPoll.value?()

        // then
        await waitUntil(timeout: 3) { callCount.value > callsAfterStart }
        #expect(callCount.value > callsAfterStart)
        withExtendedLifetime(sut) {}
    }

    @Test func givenTheSafetyPollFires_whenThereIsAListError_thenItRefreshes() async {
        // given — the very first refresh (inside `start()`) fails, leaving `listError` set, no
        // running tasks (the listing never succeeded), and "now" never advances.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PbRepoTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = LockedBox(Date())
        let (scheduler, capturedPoll) = makePollCapturingScheduler(now: now)
        let (client, callCount) = countingCtl { #"{"v":2,"error":{"code":"session_busy","message":"boom"}}"# }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(dir.path)
        given(toolEnvironment).ctl().willReturn(.success(client))
        let sut = makeSUT(toolEnvironment: toolEnvironment, scheduler: scheduler)
        sut.start()
        await waitUntil { sut.listError != nil }
        // See the note in `whenTheReconcileIntervalHasElapsed_thenItRefreshes` on why the captured
        // poll closure must be waited for before firing it.
        await waitUntil { capturedPoll.value != nil }
        #expect(capturedPoll.value != nil)
        let callsAfterStart = callCount.value

        // when
        capturedPoll.value?()

        // then
        await waitUntil(timeout: 3) { callCount.value > callsAfterStart }
        #expect(callCount.value > callsAfterStart)
        withExtendedLifetime(sut) {}
    }

    @Test func givenTheSafetyPollFires_whenTheWatcherIsInactive_thenItRefreshes() async {
        // given — the tasks folder does not exist at `start()` time, so `DirectoryWatcher.start()`
        // no-ops and stays inactive; the listing itself still succeeds (empty), "now" never
        // advances, and there is no running task — only "watcher inactive" can explain the refresh.
        let missingDir = FileManager.default.temporaryDirectory.appendingPathComponent("PbRepoTests-missing-\(UUID().uuidString)").path
        let now = LockedBox(Date())
        let (scheduler, capturedPoll) = makePollCapturingScheduler(now: now)
        let (client, callCount) = countingCtl { #"{"v":2,"tasks":[]}"# }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(missingDir)
        given(toolEnvironment).ctl().willReturn(.success(client))
        let sut = makeSUT(toolEnvironment: toolEnvironment, scheduler: scheduler)
        sut.start()
        await waitUntil { sut.hasListed }
        // See the note in `whenTheReconcileIntervalHasElapsed_thenItRefreshes` on why the captured
        // poll closure must be waited for before firing it.
        await waitUntil { capturedPoll.value != nil }
        #expect(capturedPoll.value != nil)
        let callsAfterStart = callCount.value

        // when
        capturedPoll.value?()

        // then
        await waitUntil(timeout: 3) { callCount.value > callsAfterStart }
        #expect(callCount.value > callsAfterStart)
        withExtendedLifetime(sut) {}
    }

    @Test func givenTheSafetyPollFires_whenNoConditionHolds_thenItDoesNotRefresh() async {
        // given — reconcile not due, no running task, no list error, and the watcher is attached: no
        // condition holds.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PbRepoTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = LockedBox(Date())
        let (scheduler, capturedPoll) = makePollCapturingScheduler(now: now)
        let (client, callCount) = countingCtl { #"{"v":2,"tasks":[]}"# }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(dir.path)
        given(toolEnvironment).ctl().willReturn(.success(client))
        let sut = makeSUT(toolEnvironment: toolEnvironment, scheduler: scheduler)
        sut.start()
        await waitUntil { sut.hasListed }
        // The poll closure must actually have been captured before firing it below — otherwise
        // `capturedPoll.value?()` silently no-ops on `nil` and the "then" assertion passes without
        // ever exercising the guard under test. (Same `startWatching()` race as the other safety-poll
        // tests: `hasListed` becomes true before `scheduleRepeating` is called.)
        await waitUntil { capturedPoll.value != nil }
        #expect(capturedPoll.value != nil)
        let callsAfterStart = callCount.value

        // when — really invoke the captured closure (not a no-op on `nil`).
        capturedPoll.value?()
        // No condition holds, so nothing should happen — briefly give any (wrongly) triggered async
        // work a chance to run before asserting the negative. This is not a wait on the mechanism
        // under test (the 10 s/60 s timers are never real here); it only lets an already-dispatched
        // `Task` finish, the same way other tests in this file settle a fire-and-forget `Task`.
        try? await Task.sleep(for: .milliseconds(100))

        // then
        #expect(callCount.value == callsAfterStart)
        withExtendedLifetime(sut) {}
    }

    // MARK: F4-10 — an inactive watcher restarts once its folder appears

    @Test func givenAnInactiveWatcher_whenARefreshRunsAfterItsFolderAppears_thenTheWatcherRestartsAndForwardsEvents() async {
        // given — the folder does not exist at `start()` time, so the watcher starts inactive.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PbRepoTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let scheduler = MockScheduling()
        given(scheduler).now().willReturn(Date())
        given(scheduler).scheduleRepeating(every: .any, execute: .any).willReturn(AnyCancellable {})
        given(scheduler).schedule(after: .any, execute: .any).willReturn(AnyCancellable {})
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(dir.path)
        given(toolEnvironment).ctl().willReturn(.success(ctlClient(listing: [])))
        let sut = makeSUT(toolEnvironment: toolEnvironment, scheduler: scheduler)
        sut.start()
        await waitUntil { sut.hasListed }

        // when — the folder appears, then a refresh runs. `refresh()`'s own `restartWatcherIfInactive`
        // is the mechanism under test: it must retry attaching, now that the folder exists.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await sut.refresh()

        // then — proven indirectly, since watcher state is private: write a file that should trigger
        // a real FSEvent only if the watcher is now actually attached, and confirm the throttle fires
        // because of it.
        try? "x".write(toFile: dir.path + "/restarted.meta.json", atomically: true, encoding: .utf8)
        await verify(scheduler).schedule(after: .value(1), execute: .any).calledEventually(.atLeastOnce, before: .seconds(3))
    }

    // MARK: MS-LIST-5 — titles

    @Test func givenAnExistingTitle_whenTitlesReload_thenItIsNeverOverwritten() async {
        // given
        let tasksDir = FileManager.default.temporaryDirectory.appendingPathComponent("PbRepoTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tasksDir) }
        let eventsFile = tasksDir.appendingPathComponent("t1.events.jsonl")
        // `TaskTitle.firstPrompt` finds the first line by locating a "\n" delimiter — a real
        // events.jsonl always ends each line that way, so the fixture must too.
        try? (#"{"v":1,"seq":1,"kind":"task_started","prompt":"first title"}"# + "\n").write(to: eventsFile, atomically: true, encoding: .utf8)

        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(tasksDir.path)
        given(toolEnvironment).ctl().willReturn(.success(ctlClient(listing: ["t1"])))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when — the first refresh discovers "first title" from disk; the file is then rewritten
        // with different content before a second refresh runs, which must not overwrite the title
        // already on record (F4-11: "merges keep the old value").
        await sut.refresh()
        await waitUntil { sut.titles["t1"] != nil }
        #expect(sut.titles["t1"] == "first title")

        try? (#"{"v":1,"seq":1,"kind":"task_started","prompt":"second title"}"# + "\n").write(to: eventsFile, atomically: true, encoding: .utf8)
        await sut.refresh()
        try? await Task.sleep(for: .milliseconds(200)) // give the off-main title load a chance to (wrongly) run

        // then
        #expect(sut.titles["t1"] == "first title")
    }

    @Test func givenNoTitleFound_whenDisplayed_thenTheFallbackIsTaskPlusFirst8Chars() async {
        // given
        let sut = makeSUT()

        // when / then
        #expect(sut.title("abcdefgh12345") == "Task abcdefgh")
    }

    @Test func givenMoreThan500MissingTitles_whenLoaded_thenOnly500AreFetched() async {
        // given — MS-LIST-5/F4-11: titles are loaded off-main, capped at 500 missing ids per
        // refresh. 501 tasks are listed, each with a real, readable events file, so every one of
        // them *could* resolve a title — only the cap should stop the 501st from getting one.
        let tasksDir = FileManager.default.temporaryDirectory.appendingPathComponent("PbRepoTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tasksDir) }
        let ids = (0 ..< 501).map { "task\(String(format: "%04d", $0))" }
        for id in ids {
            try? (#"{"v":1,"seq":1,"kind":"task_started","prompt":"prompt for \#(id)"}"# + "\n")
                .write(to: tasksDir.appendingPathComponent("\(id).events.jsonl"), atomically: true, encoding: .utf8)
        }
        let listingJSON = "[" + ids.map { #"{"task_id":"\#($0)","status":"completed","backend":"claude"}"# }.joined(separator: ",") + "]"
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(tasksDir.path)
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(
            executable: "/bin/echo", environment: [:],
            runner: StubProcessRunner(output: stdout(#"{"v":2,"tasks":\#(listingJSON)}"#))
        )))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when
        await sut.refresh()
        await waitUntil(timeout: 5) { sut.titles.count >= 500 }
        try? await Task.sleep(for: .milliseconds(150)) // let a (wrongly) uncapped load finish loading the 501st

        // then — exactly 500, never all 501.
        #expect(sut.titles.count == 500)
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

    @Test func givenATaskGoneFromTheListing_whenAskedForDetail_thenNilIsReturned() async {
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
        #expect(detail == nil)
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
        given(toolEnvironmentNotFound).ctl().willReturn(.failure(.notFound(tool: "polybridge-ctl", searched: [])))
        let notFoundSUT = makeSUT(toolEnvironment: toolEnvironmentNotFound)
        await notFoundSUT.refresh()
        #expect(notFoundSUT.connectionLine == "polybridge-ctl not found")

        // given: some other failure.
        let toolEnvironmentUnreadable = MockToolEnvironmentRepository()
        given(toolEnvironmentUnreadable).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        given(toolEnvironmentUnreadable).ctl().willReturn(.failure(.unreadable(tool: "polybridge-ctl", exitCode: 1, stderr: "boom")))
        let unreadableSUT = makeSUT(toolEnvironment: toolEnvironmentUnreadable)
        await unreadableSUT.refresh()
        #expect(unreadableSUT.connectionLine == "polybridge not readable")

        // given: connected, with backends.
        let toolEnvironmentConnected = MockToolEnvironmentRepository()
        given(toolEnvironmentConnected).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        given(toolEnvironmentConnected).ctl().willReturn(.success(ctlClient(listing: ["a"])))
        let connectedSUT = makeSUT(toolEnvironment: toolEnvironmentConnected)
        await connectedSUT.refresh()
        #expect(connectedSUT.connectionLine == "polybridge connected · claude")
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
        let doneRunner = StubProcessRunner(output: stdout(#"{"v":2,"tasks":[{"task_id":"a","status":"completed","backend":"claude","depth":0}]}"#))
        resultBox.mutate { $0 = .success(CtlClient(executable: "/bin/echo", environment: [:], runner: doneRunner)) }
        await sut.refresh()

        // then
        #expect(notified.value.map(\.taskID) == ["a"])
    }

    // MARK: runningInSubtrees

    @Test func givenARunningSubTask_whenCountingRunningSubtrees_thenItIsIncluded() async {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let runner = StubProcessRunner(output: stdout(
            #"{"v":2,"tasks":[{"task_id":"root","status":"completed","backend":"claude","depth":0},"#
                + #"{"task_id":"child","status":"running","backend":"claude","spawned_by":"root","depth":1}]}"#
        ))
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = makeSUT(toolEnvironment: toolEnvironment)
        await sut.refresh()

        // when
        let running = sut.runningInSubtrees(of: ["root"])

        // then
        #expect(running == ["child"])
    }

    // MARK: start()

    @Test func givenStartCalledTwice_whenObserved_thenDiscoveryOnlyRunsOnce() async {
        // given — an isolated directory: `start()` attaches a real FSEvents watcher to it, and a
        // shared temp root would pick up noise from every other test running concurrently.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PbRepoTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(dir.path)
        given(toolEnvironment).ctl().willReturn(.success(ctlClient(listing: [])))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when
        sut.start()
        sut.start()
        await waitUntil { sut.hasListed }
        try? await Task.sleep(for: .milliseconds(50))

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
