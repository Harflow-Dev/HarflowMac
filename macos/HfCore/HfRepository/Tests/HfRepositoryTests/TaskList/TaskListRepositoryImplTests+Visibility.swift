import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
import Testing

extension TaskListRepositoryImplTests {

    private func hiddenVisibility(popoverOpen: Bool = false) -> MockMonitorVisibility {
        let visibility = MockMonitorVisibility()
        given(visibility).mainWindowVisible.willReturn(false)
        given(visibility).menuBarPopoverOpen.willReturn(popoverOpen)
        return visibility
    }

    private func scriptedCtl(_ body: LockedBox<String>) -> (client: CtlClient, calls: LockedBox<Int>) {
        let calls = LockedBox(0)
        let runner = StubProcessRunner { _ in
            calls.mutate { $0 += 1 }
            return .success(stdout(body.value))
        }
        return (CtlClient(executable: "/bin/echo", environment: [:], runner: PositiveCtlRunner(runner)), calls)
    }

    private func page(items: String, totalActive: Int = 0) -> String {
        #"{"product":"harflow","format":"harflow.ctl","v":1,"product_version":"0.0.1","result":{"items":[\#(items)],"#
            + #""next_cursor":null,"has_more":false,"bootstrap_pending":false,"total_active_count":\#(totalActive)}}"#
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
        let now: LockedBox<Date>
    }

    private func startedRig(body initial: String, visibility: MockMonitorVisibility, tasksDirectory: URL? = nil) async -> PollRig {
        let dir = tasksDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("HfRepoTests-\(UUID().uuidString)")
        let now = LockedBox(Date())
        let poll = LockedBox<(@Sendable () -> Void)?>(nil)
        let scheduler = MockScheduling()
        given(scheduler).now().willProduce { now.value }
        given(scheduler).schedule(after: .any, execute: .any).willReturn(AnyCancellable {})
        given(scheduler).scheduleRepeating(every: .value(1), execute: .any).willProduce { _, work in
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
        return PollRig(sut: sut, poll: poll, calls: calls, body: body, now: now)
    }

    private func fireTicks(_ rig: PollRig, count: Int) async {
        for _ in 0 ..< count {
            let before = rig.sut.safetyPollEvaluationCount
            rig.now.mutate { $0 = $0.addingTimeInterval(1) }
            rig.poll.value?()
            await waitUntil(timeout: 5) { rig.sut.safetyPollEvaluationCount > before }
        }
    }

    @Test func givenHiddenWithARunningTask_whenTheSafetyPollFires_thenEveryTickRefreshes() async {
        // given
        let rig = await startedRig(body: page(items: runningTask(duration: 1)), visibility: hiddenVisibility())

        for _ in 0 ..< 2 {
            let before = rig.calls.value
            await fireTicks(rig, count: 1)
            #expect(rig.calls.value > before)
        }
        withExtendedLifetime(rig.sut) {}
    }

    @Test func givenVisibleAndIdle_whenTheSafetyPollFires_thenEveryTickRefreshes() async {
        // given
        let visibility = MockMonitorVisibility()
        given(visibility).mainWindowVisible.willReturn(true)
        given(visibility).menuBarPopoverOpen.willReturn(false)
        let rig = await startedRig(body: page(items: ""), visibility: visibility)
        let started = rig.calls.value

        // when
        await fireTicks(rig, count: 6)

        #expect(rig.calls.value > started)
        withExtendedLifetime(rig.sut) {}
    }

    @Test func givenHiddenButPopoverOpen_whenTheSafetyPollFires_thenItKeepsTheVisiblePolicy() async {
        // given
        let rig = await startedRig(body: page(items: ""), visibility: hiddenVisibility(popoverOpen: true))
        let started = rig.calls.value

        await fireTicks(rig, count: 3)

        // then
        #expect(rig.calls.value > started)
        withExtendedLifetime(rig.sut) {}
    }

    // MARK: Dedup (B2)

    @Test func givenARunningTaskWithAStart_whenOnlyItsDurationChanges_thenNothingRepublishes() async {
        // given
        let rig = await startedRig(body: page(items: runningTask(duration: 5)), visibility: hiddenVisibility())
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HfRepoTests-\(UUID().uuidString)")
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
