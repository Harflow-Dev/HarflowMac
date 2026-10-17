import Combine
import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
import PbTestUtilities
import Testing

// MARK: - TaskListRepositoryImpl visibility gating, dedup and counts (B1, B2)

extension TaskListRepositoryImplTests {

    private func hiddenVisibility(popoverOpen: Bool = false) -> MockMonitorVisibility {
        let visibility = MockMonitorVisibility()
        given(visibility).mainWindowVisible.willReturn(false)
        given(visibility).menuBarPopoverOpen.willReturn(popoverOpen)
        return visibility
    }

    /// A ctl whose listing is whatever the box currently holds, counting every process it runs.
    private func scriptedCtl(_ body: LockedBox<String>) -> (client: CtlClient, calls: LockedBox<Int>) {
        let calls = LockedBox(0)
        let runner = StubProcessRunner { _ in
            calls.mutate { $0 += 1 }
            return .success(stdout(body.value))
        }
        return (CtlClient(executable: "/bin/echo", environment: [:], runner: runner), calls)
    }

    private func page(items: String, totalActive: Int = 0) -> String {
        #"{"v":5,"result":{"items":[\#(items)],"next_cursor":null,"has_more":false,"bootstrap_pending":false,"total_active_count":\#(totalActive)}}"#
    }

    private func runningTask(duration: Int, started: Bool = true) -> String {
        let start = started ? #","started_at":"2026-10-17T10:00:00+00:00""# : ""
        return #"{"task_id":"a","status":"running","backend":"claude","duration_seconds":\#(duration)\#(start)}"#
    }

    private struct PollRig {
        let sut: TaskListRepositoryImpl
        let poll: LockedBox<(@Sendable () -> Void)?>
        let calls: LockedBox<Int>
        let body: LockedBox<String>
        let dir: URL
    }

    /// Starts a repository against a real (existing) tasks folder with a capturing scheduler, so
    /// the 10 s poll closure is fired by the test and the watcher counts as active.
    private func startedRig(body initial: String, visibility: MockMonitorVisibility, tasksDirectory: URL? = nil) async -> PollRig {
        let dir = tasksDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("PbRepoTests-\(UUID().uuidString)")
        if tasksDirectory == nil { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let now = LockedBox(Date())
        let poll = LockedBox<(@Sendable () -> Void)?>(nil)
        let scheduler = MockScheduling()
        given(scheduler).now().willProduce { now.value }
        given(scheduler).schedule(after: .any, execute: .any).willReturn(AnyCancellable {})
        given(scheduler).scheduleRepeating(every: .value(10), execute: .any).willProduce { _, work in
            poll.mutate { $0 = work }
            return AnyCancellable {}
        }
        let body = LockedBox(initial)
        let (client, calls) = scriptedCtl(body)
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(dir.path)
        given(toolEnvironment).ctl().willReturn(.success(client))
        let sut = makeSUT(toolEnvironment: toolEnvironment, scheduler: scheduler, visibility: visibility)
        sut.start()
        await waitUntil { sut.hasListed }
        await waitUntil { poll.value != nil }
        return PollRig(sut: sut, poll: poll, calls: calls, body: body, dir: dir)
    }

    private func fireTicks(_ rig: PollRig, count: Int) async {
        for _ in 0 ..< count {
            let before = rig.sut.safetyPollEvaluationCount
            rig.poll.value?()
            await waitUntil(timeout: 5) { rig.sut.safetyPollEvaluationCount > before }
        }
    }

    // MARK: Hidden polling cadence

    @Test func givenHiddenAndIdle_whenNoTriggerHolds_thenNoTickRefreshes() async {
        // given — hidden, nothing running, watcher attached, reconcile not due.
        let rig = await startedRig(body: page(items: ""), visibility: hiddenVisibility())
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let started = rig.calls.value

        // when — several full 30 s cycles.
        await fireTicks(rig, count: 9)

        // then — hidden never refreshes more often than visible: the triggers gate it too.
        #expect(rig.calls.value == started)
        withExtendedLifetime(rig.sut) {}
    }

    @Test func givenHiddenAndIdle_whenATriggerHolds_thenOnlyEveryThirdTickActsOnIt() async {
        // given — hidden, idle, but the watcher is down (the tasks folder does not exist).
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("PbRepoTests-missing-\(UUID().uuidString)")
        let rig = await startedRig(body: page(items: ""), visibility: hiddenVisibility(), tasksDirectory: missing)
        let started = rig.calls.value

        // when — two ticks
        await fireTicks(rig, count: 2)

        // then — nothing yet
        #expect(rig.calls.value == started)

        // when — the third tick
        await fireTicks(rig, count: 1)

        // then — the trigger is acted on, and the cycle restarts.
        let afterThird = rig.calls.value
        #expect(afterThird > started)
        await fireTicks(rig, count: 2)
        #expect(rig.calls.value == afterThird)
        withExtendedLifetime(rig.sut) {}
    }

    @Test func givenHiddenWithARunningTask_whenTheSafetyPollFires_thenEveryTickRefreshes() async {
        // given
        let rig = await startedRig(body: page(items: runningTask(duration: 1)), visibility: hiddenVisibility())
        defer { try? FileManager.default.removeItem(at: rig.dir) }

        // when / then — a running task keeps the 10 s urgency while hidden.
        for _ in 0 ..< 2 {
            let before = rig.calls.value
            await fireTicks(rig, count: 1)
            #expect(rig.calls.value > before)
        }
        withExtendedLifetime(rig.sut) {}
    }

    @Test func givenVisibleAndIdle_whenTheSafetyPollFires_thenNothingRefreshesBetweenReconciles() async {
        // given
        let visibility = MockMonitorVisibility()
        given(visibility).mainWindowVisible.willReturn(true)
        given(visibility).menuBarPopoverOpen.willReturn(false)
        let rig = await startedRig(body: page(items: ""), visibility: visibility)
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let started = rig.calls.value

        // when
        await fireTicks(rig, count: 6)

        // then — visible and idle keeps the original policy: no refresh until the reconcile is due.
        #expect(rig.calls.value == started)
        withExtendedLifetime(rig.sut) {}
    }

    @Test func givenHiddenButPopoverOpen_whenTheSafetyPollFires_thenItKeepsTheVisiblePolicy() async {
        // given
        let rig = await startedRig(body: page(items: ""), visibility: hiddenVisibility(popoverOpen: true))
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let started = rig.calls.value

        // when — three ticks would be the hidden-idle catch-up, but an open popover is "visible".
        await fireTicks(rig, count: 3)

        // then
        #expect(rig.calls.value == started)
        withExtendedLifetime(rig.sut) {}
    }

    // MARK: Dedup (B2)

    @Test func givenARunningTaskWithAStart_whenOnlyItsDurationChanges_thenNothingRepublishes() async {
        // given
        let rig = await startedRig(body: page(items: runningTask(duration: 5)), visibility: hiddenVisibility())
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let published = LockedBox(0)
        let token = rig.sut.tasksPublisher().sink { _ in published.mutate { $0 += 1 } }
        let initial = published.value

        // when
        rig.body.mutate { $0 = page(items: runningTask(duration: 17)) }
        await rig.sut.refresh()

        // then — the duration drift of a started, running task carries no state.
        #expect(published.value == initial)
        token.cancel()
        withExtendedLifetime(rig.sut) {}
    }

    @Test func givenARunningTaskWithoutAStart_whenItsDurationChanges_thenItRepublishes() async {
        // given
        let rig = await startedRig(body: page(items: runningTask(duration: 5, started: false)), visibility: hiddenVisibility())
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let published = LockedBox(0)
        let token = rig.sut.tasksPublisher().sink { _ in published.mutate { $0 += 1 } }
        let initial = published.value

        // when
        rig.body.mutate { $0 = page(items: runningTask(duration: 17, started: false)) }
        await rig.sut.refresh()

        // then — without a start time the duration is that task's only clock, so it is real state.
        #expect(published.value == initial + 1)
        token.cancel()
        withExtendedLifetime(rig.sut) {}
    }

    @Test func givenIdenticalTasks_whenTheCatalogCountsChange_thenOnlyTheCountsChannelPublishes() async {
        // given
        let rig = await startedRig(body: page(items: runningTask(duration: 5), totalActive: 1), visibility: hiddenVisibility())
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let taskPublications = LockedBox(0)
        let counts = LockedBox<[TaskListCounts]>([])
        let taskToken = rig.sut.tasksPublisher().sink { _ in taskPublications.mutate { $0 += 1 } }
        let countsToken = rig.sut.countsPublisher().sink { value in counts.mutate { $0.append(value) } }
        let initialTaskPublications = taskPublications.value
        let initialCounts = counts.value.count

        // when — the same task, but the catalog now reports more active tasks overall.
        rig.body.mutate { $0 = page(items: runningTask(duration: 6), totalActive: 4) }
        await rig.sut.refresh()

        // then
        #expect(taskPublications.value == initialTaskPublications)
        #expect(counts.value.count == initialCounts + 1)
        #expect(counts.value.last?.runningCount == 4)

        // and — an unchanged refresh publishes nothing on either channel.
        await rig.sut.refresh()
        #expect(taskPublications.value == initialTaskPublications)
        #expect(counts.value.count == initialCounts + 1)
        taskToken.cancel()
        countsToken.cancel()
        withExtendedLifetime(rig.sut) {}
    }

    // MARK: Batched snapshot refresh (B3)

    @Test func givenLeasedRunningTasks_whenAPassCompletes_thenOneBatchRefreshCoversThem() async {
        // given
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PbRepoTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = LockedBox(page(items: #"{"task_id":"a","status":"running","backend":"claude"},{"task_id":"b","status":"running","backend":"claude"}"#))
        let (client, _) = scriptedCtl(body)
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(dir.path)
        given(toolEnvironment).ctl().willReturn(.success(client))
        let snapshots = MockTaskSnapshotRepository()
        let events = MockEventStreamRepository()
        let sut = makeSUT(toolEnvironment: toolEnvironment, snapshotRepository: snapshots, eventStreamRepository: events)
        given(events).leasedTaskIDs.willReturn(["a", "b"])

        // when
        await sut.refresh()

        // then — never a per-id `refresh(_:)` loop.
        await verify(snapshots).refresh(ids: .any).calledEventually(.atLeastOnce, before: .seconds(3))
        verify(snapshots).refresh(.any).called(0)
        withExtendedLifetime(sut) {}
    }
}
