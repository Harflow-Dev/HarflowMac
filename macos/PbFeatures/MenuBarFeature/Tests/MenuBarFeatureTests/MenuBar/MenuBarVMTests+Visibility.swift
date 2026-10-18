import Combine
import Foundation
@testable import MenuBarFeature
import Mockable
import MonitorCore
import Observation
import PbCommon
import PbRepository
import PbTestUtilities
import Testing

// MARK: - MenuBarVM counts channel, popover state and minute tick (B1, B2)

extension MenuBarVMTests {

    @Test func givenIdenticalTasks_whenTheCountsChannelPublishes_thenTheLabelFollowsWithoutARowRecompute() async {
        // given
        let harness = makeSUT()
        harness.sut.didAppear()
        #expect(harness.sut.runningCount == 0)

        // when — only the counts channel moves; the task array never republishes.
        harness.countsSubject.send(TaskListCounts(runningCount: 7, countsComplete: true))

        // then
        await waitUntil { harness.sut.runningCount == 7 }
        #expect(harness.sut.runningCount == 7)
        #expect(!harness.sut.taskCountsLoading)

        // and — back to provisional counts.
        harness.countsSubject.send(TaskListCounts(runningCount: 7, countsComplete: false))
        await waitUntil { harness.sut.taskCountsLoading }
        #expect(harness.sut.taskCountsLoading)
        harness.sut.didDisappear()
    }

    @Test func givenThePopoverContent_whenItOpensAndCloses_thenVisibilityIsFed() {
        // given
        let harness = makeSUT()

        // when
        harness.sut.didPopoverOpen()
        harness.sut.didPopoverClose()

        // then
        #expect(harness.visibility.popoverWrites == [true, false])
        #expect(!harness.visibility.menuBarPopoverOpen)
    }

    @Test func givenAMinuteAlignedClock_whenThePopoverOpens_thenAOneShotPrecedesTheSixtySecondRepeat() async {
        // given — the capturing scheduler's clock sits exactly on a minute boundary.
        let harness = makeSUT()

        // when
        harness.sut.didPopoverOpen()

        // then — first the aligning one-shot (a full minute away, never zero), and no repeat yet.
        #expect(harness.scheduler.oneShotIntervals == [60])
        #expect(harness.scheduler.repeatIntervals.isEmpty)

        // when — the one-shot lands.
        harness.scheduler.fireOneShot(interval: 60)

        // then — the 60 s repeat takes over.
        await waitUntil { harness.scheduler.repeatIntervals == [60] }
        #expect(harness.scheduler.repeatIntervals == [60])
        harness.sut.didPopoverClose()
    }

    @Test func givenAClockMidMinute_whenThePopoverOpens_thenTheOneShotReachesTheNextBoundary() {
        // given
        let scheduler = CapturingScheduler()
        scheduler.advance(to: scheduler.now().addingTimeInterval(20))
        let harness = makeSUT(scheduler: scheduler)

        // when
        harness.sut.didPopoverOpen()

        // then
        #expect(harness.scheduler.oneShotIntervals.count == 1)
        #expect(abs((harness.scheduler.oneShotIntervals.first ?? 0) - 40) < 0.001)
    }

    @Test func givenAnOpenPopover_whenTheMinuteTicks_thenTheContentRecomputesWithNoPublication() async {
        // given — a running count the repository changed without any publisher emitting.
        let harness = makeSUT()
        harness.sut.didAppear()
        harness.sut.didPopoverOpen()
        harness.scheduler.fireOneShot(interval: 60)
        await waitUntil { harness.scheduler.repeatIntervals == [60] }
        harness.runningCountBox.value = 5
        given(harness.useCase).runningCount.willProduce { harness.runningCountBox.value }

        // when
        harness.scheduler.fireFirstRepeat()

        // then — the tick alone refreshed the time-derived presentation.
        await waitUntil { harness.sut.runningCount == 5 }
        #expect(harness.sut.runningCount == 5)
        harness.sut.didPopoverClose()
        harness.sut.didDisappear()
    }

    @Test func givenAFiredOneShot_whenThePopoverClosesBeforeTheQueuedTaskRuns_thenNoRepeatIsInstalledAndNothingRecomputes() async {
        // given
        let harness = makeSUT()
        harness.sut.didAppear()
        harness.sut.didPopoverOpen()
        harness.runningCountBox.value = 8

        // when — the one-shot fires (queueing its main-actor task), the popover closes (stopping
        // the clock) before that task can run, then the queue drains.
        harness.scheduler.fireOneShot(interval: 60)
        harness.sut.didPopoverClose()
        for _ in 0 ..< 5 { await Task.yield() }

        // then
        #expect(harness.scheduler.repeatIntervals.isEmpty)
        #expect(harness.sut.runningCount != 8)
        harness.sut.didDisappear()
    }

    @Test func givenAClosedPopover_whenTheMinuteTicks_thenNothingRecomputes() async {
        // given — the tick keeps running (the status item is always on screen), the popover is closed.
        let harness = makeSUT()
        harness.sut.didAppear()
        harness.sut.didPopoverOpen()
        harness.scheduler.fireOneShot(interval: 60)
        await waitUntil { harness.scheduler.repeatIntervals == [60] }
        harness.sut.didPopoverClose()
        harness.runningCountBox.value = 9

        // when
        harness.scheduler.fireFirstRepeat()
        await Task.yield()

        // then
        #expect(harness.sut.runningCount != 9)
        harness.sut.didDisappear()
    }
}

// MARK: - WorkflowMenuBarStatusVM cadence and dedup (B1, B2)

extension WorkflowMenuBarStatusVMTests {

    private final class RunCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    @Test(arguments: [(true, false, 2.0), (false, true, 2.0), (true, true, 2.0), (false, false, 10.0)])
    func givenVisibilityStates_whenThePollIntervalIsRead_thenOnlyAFullyHiddenMonitorStretchesIt(
        windowVisible: Bool, popoverOpen: Bool, expected: Double
    ) {
        // given
        let visibility = FakeMonitorVisibility(mainWindowVisible: windowVisible)
        visibility.setMenuBarPopoverOpen(popoverOpen)
        let sut = WorkflowMenuBarStatusVM(useCase: MockWorkflowMenuBarUseCase(), visibility: visibility, scheduler: CapturingScheduler())

        // when / then
        #expect(sut.pollInterval == expected)
    }

    @Test func givenAVisibleMonitor_whenAPassCompletes_thenTheNextPassWaitsTwoSecondsOnTheScheduler() async {
        // given
        let useCase = MockWorkflowMenuBarUseCase()
        let calls = RunCalls()
        given(useCase).runs().willProduce { calls.increment(); return [] }
        let scheduler = CapturingScheduler()
        let sut = WorkflowMenuBarStatusVM(useCase: useCase, visibility: FakeMonitorVisibility(), scheduler: scheduler)

        // when
        sut.didAppear()
        await waitUntil { scheduler.oneShotCount(interval: 2) == 1 }

        // then — the first pass ran and the second waits for the scheduled tick.
        #expect(calls.value == 1)
        scheduler.fireOneShot(interval: 2)
        await waitUntil { calls.value == 2 }
        #expect(calls.value == 2)
        sut.didDisappear()
    }

    @Test func givenAHiddenMonitor_whenAPassCompletes_thenTheNextPassWaitsTenSeconds() async {
        // given
        let useCase = MockWorkflowMenuBarUseCase()
        given(useCase).runs().willReturn([])
        let scheduler = CapturingScheduler()
        let sut = WorkflowMenuBarStatusVM(useCase: useCase, visibility: FakeMonitorVisibility(mainWindowVisible: false), scheduler: scheduler)

        // when
        sut.didAppear()

        // then
        await waitUntil { scheduler.oneShotCount(interval: 10) == 1 }
        #expect(scheduler.oneShotCount(interval: 10) == 1)
        #expect(scheduler.oneShotCount(interval: 2) == 0)
        sut.didDisappear()
    }

    @Test(arguments: [true, false])
    func givenAHiddenMonitorWaitingTenSeconds_whenThePopoverOpensOrTheWindowShows_thenItRefreshesAtOnce(popover: Bool) async {
        // given — hidden, one pass done, parked in the 10 s wait.
        let useCase = MockWorkflowMenuBarUseCase()
        let calls = RunCalls()
        given(useCase).runs().willProduce { calls.increment(); return [] }
        let scheduler = CapturingScheduler()
        let visibility = FakeMonitorVisibility(mainWindowVisible: false)
        let sut = WorkflowMenuBarStatusVM(useCase: useCase, visibility: visibility, scheduler: scheduler)
        sut.didAppear()
        await waitUntil { scheduler.oneShotCount(interval: 10) == 1 }
        #expect(calls.value == 1)

        // when
        if popover { visibility.setMenuBarPopoverOpen(true) } else { visibility.setMainWindowVisible(true) }

        // then — no tick fired by the test; the transition alone woke the loop.
        await waitUntil { calls.value == 2 }
        #expect(calls.value == 2)
        sut.didDisappear()
    }

    @Test func givenAnUnchangedWorkflowList_whenRefreshedAgain_thenNothingObservableIsAssigned() async {
        // given
        let useCase = MockWorkflowMenuBarUseCase()
        given(useCase).runs().willReturn([run("running", status: "running")])
        let sut = WorkflowMenuBarStatusVM(useCase: useCase, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        await sut.refresh()
        #expect(sut.activeCount == 1)
        let changed = LockedBox(false)

        // when
        withObservationTracking {
            _ = sut.rows
            _ = sut.countsLoading
            _ = sut.errorText
            _ = sut.activeCount
            _ = sut.attentionCount
        } onChange: {
            changed.mutate { $0 = true }
        }
        await sut.refresh()

        // then — equal values are compared before assignment, so no observer is invalidated.
        #expect(!changed.value)
    }

    @Test func givenAChangedWorkflowList_whenRefreshedAgain_thenObserversAreInvalidated() async {
        // given
        let useCase = MockWorkflowMenuBarUseCase()
        let status = LockedBox("running")
        given(useCase).runs().willProduce { [self.run("running", status: status.value)] }
        let sut = WorkflowMenuBarStatusVM(useCase: useCase, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        await sut.refresh()
        let changed = LockedBox(false)
        withObservationTracking { _ = sut.rows } onChange: { changed.mutate { $0 = true } }

        // when
        status.mutate { $0 = "paused" }
        await sut.refresh()

        // then
        #expect(changed.value)
    }
}
