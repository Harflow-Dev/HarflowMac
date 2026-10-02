import Foundation
@testable import MainWindowFeature
import PbTestUtilities
import Testing

extension ParallelVMTests {
    @Test func givenWorkflowAssociations_whenTasksResume_thenExistingConversationFeedAndLeasesAreReused() async {
        // given
        let harness = makeSUT()
        let first = task(id: "first", status: "completed", startedAt: Date(timeIntervalSince1970: 10), group: nil)
        let resumed = task(id: "resumed", startedAt: Date(timeIntervalSince1970: 20), group: nil, parentTaskID: "first")
        let unrelated = task(id: "unrelated")
        harness.tasksBox.value = [first.taskID: first, resumed.taskID: resumed, unrelated.taskID: unrelated]
        harness.sut.setWorkflowTaskIDs(["first", "resumed"], focusedTaskIDs: ["resumed"], titles: ["resumed": "Implement · 2"])
        // when
        harness.sut.didAppear()
        harness.tasksSubject.send([first, resumed, unrelated])
        await waitUntil { harness.sut.columns.count == 1 }
        // then
        #expect(harness.sut.columns.first?.task.taskID == "resumed")
        #expect(harness.sut.columns.first?.title == "Implement · 2")
        #expect(Set(harness.leasesBox.value.keys) == ["first", "resumed"])
        harness.sut.didDisappear()
        #expect(harness.releasedBox.value == ["first", "resumed"])
    }

    @Test func givenDisappearedWorkflow_whenMembershipUpdates_thenItDoesNotReacquireFeedsUntilAppearance() async {
        // given
        let harness = makeSUT()
        let member = task(id: "member", group: nil)
        harness.tasksBox.value = [member.taskID: member]
        harness.sut.didAppear()
        harness.tasksSubject.send([member])
        harness.sut.didDisappear()
        // when
        harness.sut.setWorkflowTaskIDs(["member"])
        // then
        #expect(harness.leasesBox.value.isEmpty)
        harness.sut.didAppear()
        harness.tasksSubject.send([member])
        await waitUntil { harness.sut.columns.count == 1 }
        #expect(harness.leasesBox.value["member"] != nil)
        harness.sut.didDisappear()
    }
}
