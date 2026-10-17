import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbTestUtilities
import Testing

// MARK: - Sidebar workflow poll gating and presentation clock (B1, B2)

@MainActor
private final class ScriptedSidebarWorkflows: SidebarWorkflowUseCase {
    var snapshots: [SidebarWorkflowSnapshot]
    private(set) var requests = 0
    init(_ snapshots: [SidebarWorkflowSnapshot]) { self.snapshots = snapshots }
    func workflowSnapshot() async throws -> SidebarWorkflowSnapshot {
        requests += 1
        return snapshots[min(requests, snapshots.count) - 1]
    }
}

private func runHeader(_ id: String, status: String = "running", parent: String? = nil) -> [String: JSONValue] {
    var raw: [String: JSONValue] = ["workflow_run_id": .string(id), "name": .string(id), "status": .string(status)]
    if let parent { raw["parent_workflow_run_id"] = .string(parent) }
    return raw
}

extension SidebarVMTests {

    private func countBuilds(_ harness: SUT) -> PollCounter {
        let builds = PollCounter()
        harness.sut.presentationBuild = { input in
            builds.increment()
            return SidebarPresentationBuilder.compute(input)
        }
        return builds
    }

    // MARK: Workflow poll cadence

    @Test func givenAVisibleWindow_whenAPassCompletes_thenTheNextWaitsTwoSecondsOnTheScheduler() async {
        // given
        let useCase = ScriptedSidebarWorkflows([SidebarWorkflowSnapshot(definitions: [], runs: [runHeader("r1")])])
        let scheduler = CapturingScheduler()
        let harness = makeSUT(workflowUseCase: useCase, visibility: FakeMonitorVisibility(), scheduler: scheduler)

        // when
        harness.sut.didAppear()
        await waitUntil { scheduler.oneShotCount(interval: 2) == 1 }

        // then — pass one ran; pass two waits for the scheduled tick, which the test fires.
        #expect(useCase.requests == 1)
        scheduler.fireOneShot(interval: 2)
        await waitUntil { useCase.requests == 2 }
        #expect(useCase.requests == 2)
        harness.sut.didDisappear()
    }

    @Test func givenAHiddenWindow_whenPolling_thenItParksAfterOnePassAndShowingRefreshesAtOnce() async {
        // given
        let useCase = ScriptedSidebarWorkflows([SidebarWorkflowSnapshot(definitions: [], runs: [runHeader("r1")])])
        let scheduler = CapturingScheduler()
        let visibility = FakeMonitorVisibility(mainWindowVisible: false)
        let harness = makeSUT(workflowUseCase: useCase, visibility: visibility, scheduler: scheduler)

        // when
        harness.sut.didAppear()
        await waitUntil { useCase.requests == 1 }
        await Task.yield()

        // then — parked: no 2 s tick scheduled, no second request.
        #expect(scheduler.oneShotCount(interval: 2) == 0)
        #expect(useCase.requests == 1)

        // when — the window shows.
        visibility.setMainWindowVisible(true)

        // then — an immediate refresh, then the normal 2 s cadence resumes.
        await waitUntil { useCase.requests == 2 }
        #expect(useCase.requests == 2)
        await waitUntil { scheduler.oneShotCount(interval: 2) == 1 }
        #expect(scheduler.oneShotCount(interval: 2) == 1)
        harness.sut.didDisappear()
    }

    // MARK: Recompute only on changed inputs

    @Test func givenAnUnchangedSnapshot_whenPolledAgain_thenNoRecomputeRuns() async {
        // given
        let snapshot = SidebarWorkflowSnapshot(definitions: [["name": .string("flow")]], runs: [runHeader("r1")])
        let useCase = ScriptedSidebarWorkflows([snapshot, snapshot])
        let scheduler = CapturingScheduler()
        let harness = makeSUT(workflowUseCase: useCase, visibility: FakeMonitorVisibility(), scheduler: scheduler)
        let builds = countBuilds(harness)
        harness.sut.didAppear()
        await waitUntil { scheduler.oneShotCount(interval: 2) == 1 }
        await harness.sut.waitForPresentation()
        let settled = builds.value
        #expect(settled > 0)

        // when — pass two sees exactly the same snapshot.
        scheduler.fireOneShot(interval: 2)
        await waitUntil { useCase.requests == 2 && scheduler.oneShotCount(interval: 2) == 1 }
        await harness.sut.waitForPresentation()

        // then
        #expect(builds.value == settled)
        harness.sut.didDisappear()
    }

    @Test func givenAnUnchangedParentSnapshot_whenAChildRunChanges_thenTheRecomputeRuns() async {
        // given — the parent header is identical across passes; only the child's status moves.
        let first = SidebarWorkflowSnapshot(definitions: [], runs: [runHeader("root"), runHeader("child", parent: "root")])
        let second = SidebarWorkflowSnapshot(definitions: [], runs: [runHeader("root"), runHeader("child", status: "completed", parent: "root")])
        let useCase = ScriptedSidebarWorkflows([first, second])
        let scheduler = CapturingScheduler()
        let harness = makeSUT(workflowUseCase: useCase, visibility: FakeMonitorVisibility(), scheduler: scheduler)
        let builds = countBuilds(harness)
        harness.sut.didAppear()
        await waitUntil { scheduler.oneShotCount(interval: 2) == 1 }
        await harness.sut.waitForPresentation()
        let settled = builds.value

        // when
        scheduler.fireOneShot(interval: 2)
        await waitUntil { builds.value > settled }

        // then
        #expect(builds.value > settled)
        harness.sut.didDisappear()
    }

    // MARK: Minute-aligned presentation clock

    @Test func givenAVisibleWindow_whenItAppears_thenTheTickIsAOneShotToTheBoundaryThenAMinuteRepeat() async {
        // given — the scheduler's clock is exactly on a minute boundary.
        let scheduler = CapturingScheduler()
        let harness = makeSUT(visibility: FakeMonitorVisibility(), scheduler: scheduler)
        let builds = countBuilds(harness)

        // when
        harness.sut.didAppear()
        await harness.sut.waitForPresentation()

        // then — the aligning one-shot only; the repeat is not scheduled yet.
        #expect(scheduler.oneShotIntervals == [60])
        #expect(scheduler.repeatIntervals.isEmpty)
        let afterAppear = builds.value

        // when — the one-shot fires: a recompute plus the 60 s repeat.
        scheduler.fireOneShot(interval: 60)
        await waitUntil { scheduler.repeatIntervals == [60] && builds.value > afterAppear }
        #expect(scheduler.repeatIntervals == [60])
        let afterFirstTick = builds.value

        // when — each repeat tick recomputes again, with no task publication.
        scheduler.fireFirstRepeat()
        await waitUntil { builds.value > afterFirstTick }
        #expect(builds.value > afterFirstTick)
        harness.sut.didDisappear()
    }

    @Test func givenAMidMinuteClock_whenTheTickStarts_thenTheOneShotReachesTheNextBoundary() {
        // given
        let scheduler = CapturingScheduler()
        scheduler.advance(to: scheduler.now().addingTimeInterval(25))
        let harness = makeSUT(visibility: FakeMonitorVisibility(), scheduler: scheduler)

        // when
        harness.sut.didAppear()

        // then
        #expect(scheduler.oneShotIntervals.count == 1)
        #expect(abs((scheduler.oneShotIntervals.first ?? 0) - 35) < 0.001)
        harness.sut.didDisappear()
    }

    @Test func givenAHiddenWindow_whenItAppears_thenNoTickIsScheduled() {
        // given
        let scheduler = CapturingScheduler()
        let harness = makeSUT(visibility: FakeMonitorVisibility(mainWindowVisible: false), scheduler: scheduler)

        // when
        harness.sut.didAppear()

        // then
        #expect(scheduler.oneShotIntervals.isEmpty)
        harness.sut.didDisappear()
    }

    @Test func givenAHiddenWindow_whenItIsShown_thenItRecomputesAtOnceAndRealignsTheTick() async {
        // given
        let scheduler = CapturingScheduler()
        let visibility = FakeMonitorVisibility(mainWindowVisible: false)
        let harness = makeSUT(visibility: visibility, scheduler: scheduler)
        let builds = countBuilds(harness)
        harness.sut.didAppear()
        await harness.sut.waitForPresentation()
        let hiddenBuilds = builds.value

        // when
        visibility.setMainWindowVisible(true)

        // then
        await waitUntil { builds.value > hiddenBuilds }
        #expect(builds.value > hiddenBuilds)
        #expect(scheduler.oneShotIntervals == [60])
        harness.sut.didDisappear()
    }

    @Test func givenAFiredOneShot_whenTheClockStopsBeforeTheQueuedTaskRuns_thenNoRepeatIsInstalledAndNothingRecomputes() async {
        // given
        let scheduler = CapturingScheduler()
        let harness = makeSUT(visibility: FakeMonitorVisibility(), scheduler: scheduler)
        let builds = countBuilds(harness)
        harness.sut.didAppear()
        await harness.sut.waitForPresentation()
        let settled = builds.value

        // when — the one-shot fires (queueing its main-actor task), the clock stops before that
        // task can run, then the queue drains.
        scheduler.fireOneShot(interval: 60)
        harness.sut.stopPresentationTick()
        for _ in 0 ..< 5 { await Task.yield() }
        await harness.sut.waitForPresentation()

        // then
        #expect(scheduler.repeatIntervals.isEmpty)
        #expect(builds.value == settled)
        harness.sut.didDisappear()
    }

    @Test func givenAHiddenWindow_whenAnOldTickFires_thenItDoesNotRecompute() async {
        // given — a repeat captured while visible, then the window hides.
        let scheduler = CapturingScheduler()
        let visibility = FakeMonitorVisibility()
        let harness = makeSUT(visibility: visibility, scheduler: scheduler)
        let builds = countBuilds(harness)
        harness.sut.didAppear()
        scheduler.fireOneShot(interval: 60)
        await waitUntil { scheduler.repeatIntervals == [60] }
        await harness.sut.waitForPresentation()
        visibility.setMainWindowVisible(false)
        await Task.yield()
        let settled = builds.value

        // when
        scheduler.fireFirstRepeat()
        for _ in 0 ..< 5 { await Task.yield() }

        // then
        #expect(builds.value == settled)
        harness.sut.didDisappear()
    }

    @Test func givenNoRunningTask_whenTheMinuteTickCrossesMidnight_thenTheRowMovesFromTodayToEarlier() async throws {
        // given — a finished task started now, on the injected clock's day.
        let scheduler = CapturingScheduler()
        let start = scheduler.now()
        let harness = makeSUT(visibility: FakeMonitorVisibility(), scheduler: scheduler)
        harness.sut.didAppear()
        harness.tasksSubject.send([task(id: "done", status: "completed", startedAt: start)])
        await waitUntil { harness.sut.items(in: .today).map(\.id) == ["task:done"] }
        #expect(harness.sut.items(in: .earlier).isEmpty)

        // when — the clock passes the next local midnight and the minute tick fires. No task
        // publication, no workflow poll, nothing running.
        let midnight = try #require(Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: start)))
        scheduler.advance(to: midnight.addingTimeInterval(60))
        scheduler.fireOneShot(interval: 60)

        // then — asserted on the presentation output, built from the injected clock.
        await waitUntil { harness.sut.items(in: .earlier).map(\.id) == ["task:done"] }
        #expect(harness.sut.items(in: .earlier).map(\.id) == ["task:done"])
        #expect(harness.sut.items(in: .today).isEmpty)
        harness.sut.didDisappear()
    }
}
