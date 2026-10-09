import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Observation
import PbTestUtilities
import Testing

@MainActor
extension TaskDetailVMTests {
    @Test func givenEqualTimelineInputs_whenRecomputed_thenNoNewPresentationRevision() async {
        // given
        let harness = makeSUT()
        harness.detailBox.value = task(status: "completed")
        harness.sut.didAppear()
        harness.tasksSubject.send([harness.detailBox.value!])
        await waitUntil { harness.sut.timelineWorker == nil && harness.sut.latestTimelineInput != nil }
        let revision = harness.sut.timelineRevision
        let presentation = harness.sut.appliedTimelinePresentation
        // when
        harness.sut.recompute()
        // then
        #expect(harness.sut.timelineRevision == revision)
        #expect(harness.sut.timelineWorker == nil)
        #expect(harness.sut.appliedTimelinePresentation == presentation)
        harness.sut.didDisappear()
    }

    @Test func givenSourceRejectsOlderPage_whenHistoryPresentationWasStale_thenRequestAndLoadingClear() async {
        let member = conversationTask("current", minute: 0)
        let harness = makeConversationSUT(openedAs: "current", initialMembers: [member],
            eventHistory: { _ in EventHistoryState(hasMore: true) })
        given(harness.useCase).loadMoreEvents(.value("current")).willReturn(false)
        harness.sut.didAppear()
        await waitUntil { harness.sut.timelineWorker == nil && harness.sut.latestTimelineInput != nil && !harness.sut.conversationLoading }
        let counter = TimelineObservationCounter()
        withObservationTracking { _ = harness.sut.timelineModel } onChange: {
            Task { @MainActor in counter.writes += 1 }
        }
        let accepted = harness.sut.loadMoreConversationActivity()
        await waitUntil { harness.sut.timelineWorker == nil && !harness.sut.timelineModel.history.isLoading }
        for _ in 0 ..< 10 { await Task.yield() }
        #expect(counter.writes == 0)
        #expect(!accepted)
        #expect(!harness.sut.olderActivityRequest)
        #expect(!harness.sut.timelineModel.history.isLoading)
    }

    @Test func givenTimelineInput_whenBuiltDetached_thenRunsOffMainAndRetainsCompleteValues() async throws {
        // given
        let task = task(status: "running")
        let event = try #require(TaskEvent(line: #"{"v":1,"seq":1,"kind":"assistant_text","text":"Synthetic activity"}"#))
        let input = TaskDetailTimelineInput(task: task,
            members: [ParallelMemberInput(task: task, items: Timeline.items(from: [event]), prompt: nil, availability: .available)],
            children: [], start: task.startedAt, isBuilder: false, events: [event], snapshot: task,
            history: EventHistoryState(hasMore: true, error: "Synthetic retry", generation: 3))
        // when
        let result = try await Task.detached {
            let background = detailBackgroundThread()
            return (background, try TaskDetailTimelineBuilder.build(input))
        }
.value
        // then
        #expect(result.0)
        #expect(result.1.stepCount == 1)
        #expect(result.1.history == input.history)
        #expect(result.1.activityRows.count == 1)
    }

    @Test func givenEmptyOlderPageWithCursorProgress_whenCompleted_thenRevisionSignalsAndDuplicateRequestIsSuppressed() async {
        // given
        let member = conversationTask("current")
        let state = Box(EventHistoryState(hasMore: true, generation: 1))
        let harness = makeConversationSUT(openedAs: "current", initialMembers: [member], eventHistory: { _ in state.value })
        given(harness.useCase).loadMoreEvents(.value("current")).willProduce { _ in
            state.value = EventHistoryState(hasMore: true, generation: 2)
            return true
        }
        harness.sut.didAppear()
        await waitUntil { harness.sut.timelineWorker == nil && harness.sut.latestTimelineInput != nil && !harness.sut.conversationLoading }
        let revision = harness.sut.activityPaginationRevision
        // when
        let accepted = harness.sut.timelineModel.onLoadMore?()
        #expect(accepted == true)
        #expect(harness.sut.timelineModel.history.isLoading)
        harness.sut.timelineModel.onLoadMore?()
        await waitUntil { !harness.sut.olderActivityRequest && harness.sut.timelineWorker == nil }
        // then
        #expect(harness.sut.activityPaginationRevision == revision + 1)
        #expect(harness.sut.timelineModel.paginationRevision == revision + 1)
        verify(harness.useCase).loadMoreEvents(.value("current")).called(1)
        harness.sut.didDisappear()
    }

    @Test func givenPendingTimelineBuild_whenDisappearing_thenResultCannotRepublishAndReopenRebuilds() async {
        // given
        let harness = makeSUT()
        harness.detailBox.value = task(status: "completed")
        harness.sut.didAppear()
        // when
        harness.sut.didDisappear()
        await waitUntil { harness.sut.timelineWorker == nil }
        // then
        #expect(harness.sut.appliedTimelinePresentation == nil)
        #expect(harness.sut.latestTimelineInput == nil)
        // when
        harness.sut.didAppear()
        await waitUntil { harness.sut.timelineWorker == nil && harness.sut.appliedTimelinePresentation != nil }
        // then
        #expect(harness.sut.appliedTimelinePresentation != nil)
        harness.sut.didDisappear()
    }
}

private nonisolated func detailBackgroundThread() -> Bool { !Thread.isMainThread }

@MainActor
extension TaskDetailVMTests {
    @Test func givenOlderWorkerFinishesLate_whenInputChanges_thenOnlyNewestPresentationApplies() async {
        // given
        let harness = makeSUT()
        let gate = DetailBuildGate()
        harness.detailBox.value = task(status: "running")
        harness.sut.timelineBuild = { input in
            let value = try? TaskDetailTimelineBuilder.build(input)
            await gate.pauseFirst()
            return value
        }
        harness.sut.didAppear()
        await gate.waitUntilEntered()
        // when — deliberately ignore worker cancellation and return the older value late.
        harness.detailBox.value = task(status: "completed")
        harness.sut.recompute()
        await gate.release()
        await waitUntil { harness.sut.timelineWorker == nil && harness.sut.appliedTimelinePresentation != nil }
        // then
        #expect(harness.sut.appliedTimelinePresentation?.emptyText == "This task's event log is empty or was not found.")
        harness.sut.didDisappear()
    }
}

private actor DetailBuildGate {
    private var entered = false
    private var blocked: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?

    func pauseFirst() async {
        guard !entered else { return }
        entered = true
        await withCheckedContinuation { continuation in
            blocked = continuation
            waiting?.resume()
            waiting = nil
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func release() {
        blocked?.resume()
        blocked = nil
    }
}

@MainActor private final class TimelineObservationCounter { var writes = 0 }
