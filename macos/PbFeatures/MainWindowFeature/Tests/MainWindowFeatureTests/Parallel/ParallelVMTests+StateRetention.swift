import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import Testing

extension ParallelVMTests {
    @Test func givenPrunedFirstTurn_whenMembershipChanges_thenSurvivingConversationRetainsInteractionState() async {
        let harness = makeSUT()
        let first = task(id: "first", startedAt: Date(timeIntervalSince1970: 100))
        let last = task(id: "last", startedAt: Date(timeIntervalSince1970: 200), parentTaskID: "first")
        harness.tasksBox.value = ["first": first, "last": last]
        harness.sut.didAppear()
        harness.tasksSubject.send([first, last])
        await waitUntil { harness.sut.columns.count == 1 && harness.sut.isPresentationSettled }
        let state = harness.sut.columnState(for: "first")
        state.retainedFirstID = "retained-row"
        state.expandedGroups = ["tools"]
        state.followLive.suspend()
        state.anchor = ParallelVerticalAnchor(id: "older-row", index: 2, relativeOffset: 14)
        harness.tasksBox.value = ["last": last]
        harness.tasksSubject.send([last])
        await waitUntil { harness.sut.columns.first?.id == "last" && harness.sut.isPresentationSettled }
        let migrated = harness.sut.columnState(for: "last")
        #expect(migrated === state)
        #expect(migrated.retainedFirstID == "retained-row" && migrated.expandedGroups == ["tools"])
        #expect(!migrated.followLive.isFollowing)
        #expect(migrated.anchor == ParallelVerticalAnchor(id: "older-row", index: 2, relativeOffset: 14))
        #expect(harness.sut.retainedColumnStateCount == 1)
        harness.sut.didDisappear()
    }

    @Test func givenRemovedConversation_whenMembershipChanges_thenItsStateIsPrunedAndStaleRequestsStayUncached() async {
        let harness = makeSUT()
        let first = task(id: "first", startedAt: Date(timeIntervalSince1970: 100))
        let other = task(id: "other", startedAt: Date(timeIntervalSince1970: 200))
        harness.tasksBox.value = ["first": first, "other": other]
        harness.sut.didAppear()
        harness.tasksSubject.send([first, other])
        await waitUntil { harness.sut.columns.count == 2 && harness.sut.isPresentationSettled }
        let removed = harness.sut.columnState(for: "first")
        let kept = harness.sut.columnState(for: "other")
        harness.tasksBox.value = ["other": other]
        harness.tasksSubject.send([other])
        await waitUntil { harness.sut.columns.count == 1 && harness.sut.isPresentationSettled }
        #expect(harness.sut.retainedColumnStateCount == 1)
        #expect(harness.sut.columnState(for: "other") === kept)
        #expect(harness.sut.columnState(for: "first") !== removed)
        #expect(harness.sut.retainedColumnStateCount == 1)
        harness.sut.didDisappear()
        #expect(harness.sut.retainedColumnStateCount == 0)
    }

    @Test func givenSplitConversation_whenStateMigrates_thenOnlyOneSuccessorReusesTheState() {
        let first = task(id: "first", startedAt: Date(timeIntervalSince1970: 100))
        let second = task(id: "second", startedAt: Date(timeIntervalSince1970: 200))
        let third = task(id: "third", startedAt: Date(timeIntervalSince1970: 300))
        let mapping = ParallelStateMigration.mapping(previous: [Conversation(members: [first, second, third])],
            current: [Conversation(members: [second]), Conversation(members: [third])], retained: ["first"])
        #expect(mapping == ["second": "first"])
    }
}
