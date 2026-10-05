import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbTestUtilities
import Testing

@MainActor
extension TaskDetailVMTests {
    @Test(arguments: [false, true])
    func givenExhaustedOldestAndTwoLoadedTurnsWithWork_whenPaging_thenEveryTurnIsReachedBeforeSessionHistory(retry: Bool) async {
        let members = [conversationTask("old", minute: 0),
            conversationTask("middle", parentTaskID: "old", minute: 1), conversationTask("current", parentTaskID: "middle", minute: 2)]
        let states = Box(["old": EventHistoryState(), "middle": EventHistoryState(hasMore: !retry, error: retry ? "Retry middle" : nil),
            "current": EventHistoryState(hasMore: true)])
        let calls = Box<[String]>([])
        let harness = makeConversationSUT(openedAs: "current", initialMembers: members, eventHistory: { states.value[$0] ?? EventHistoryState() })
        let sut = harness.sut
        given(harness.useCase).loadMoreEvents(.any).willProduce { id in calls.value.append(id); states.value[id] = EventHistoryState() }
        sut.didAppear()
        harness.tasksSubject.send(members)
        await waitUntil { sut.task != nil && !sut.conversationLoading }
        sut.loadedActivityMembers = Set(members.map(\.taskID))
        sut.conversationHasMore = true
        sut.recomputeTimeline(task: members[2], allChildren: [])
        #expect(sut.timelineModel.history.hasMore)
        #expect(sut.timelineModel.history.error == (retry ? "Retry middle" : nil))
        sut.timelineModel.onLoadMore?()
        #expect(calls.value == ["middle"])
        #expect(!sut.conversationLoading)
        sut.recomputeTimeline(task: members[2], allChildren: [])
        #expect(sut.timelineModel.history.hasMore)
        sut.timelineModel.onLoadMore?()
        #expect(calls.value == ["middle", "current"])
        #expect(!sut.conversationLoading)
        sut.recomputeTimeline(task: members[2], allChildren: [])
        sut.timelineModel.onLoadMore?()
        #expect(sut.conversationLoading, "session metadata advances only after all loaded activity cursors are exhausted")
        sut.didDisappear()
    }

    @Test func givenOnlyCurrentTurnLoadedWithOlderEvents_whenPaging_thenCurrentCursorFinishesBeforeLeasingPreviousTurn() async {
        let members = [conversationTask("old", minute: 0), conversationTask("current", parentTaskID: "old", minute: 1)]
        let states = Box(["current": EventHistoryState(hasMore: true)])
        let harness = makeConversationSUT(openedAs: "current", initialMembers: members, eventHistory: { states.value[$0] ?? EventHistoryState() })
        let sut = harness.sut
        given(harness.useCase).loadMoreEvents(.value("current")).willProduce { _ in states.value["current"] = EventHistoryState() }
        sut.didAppear()
        harness.tasksSubject.send(members)
        await waitUntil { sut.task != nil && !sut.conversationLoading }
        #expect(sut.loadedActivityMembers == ["current"])
        sut.recomputeTimeline(task: members[1], allChildren: [])
        sut.timelineModel.onLoadMore?()
        verify(harness.useCase).loadMoreEvents(.value("current")).called(1)
        #expect(sut.loadedActivityMembers == ["current"])
        sut.recomputeTimeline(task: members[1], allChildren: [])
        sut.timelineModel.onLoadMore?()
        #expect(sut.loadedActivityMembers == ["old", "current"])
        sut.recomputeTimeline(task: members[1], allChildren: [])
        #expect(!sut.timelineModel.history.hasMore)
        sut.didDisappear()
    }

    @Test func givenLaterLoadedTurnLoading_whenOldestIsExhausted_thenAggregateLoadingPreventsDuplicatePaging() async {
        let members = [conversationTask("old", minute: 0), conversationTask("current", parentTaskID: "old", minute: 1)]
        let harness = makeConversationSUT(openedAs: "current", initialMembers: members,
            eventHistory: { EventHistoryState(hasMore: $0 == "current", isLoading: $0 == "current") })
        let sut = harness.sut
        sut.didAppear()
        harness.tasksSubject.send(members)
        await waitUntil { sut.task != nil }
        sut.loadedActivityMembers = Set(members.map(\.taskID))
        sut.recomputeTimeline(task: members[1], allChildren: [])
        #expect(sut.timelineModel.history.isLoading)
        #expect(sut.timelineModel.history.hasMore)
        sut.timelineModel.onLoadMore?()
        verify(harness.useCase).loadMoreEvents(.any).called(0)
        sut.didDisappear()
    }
}
