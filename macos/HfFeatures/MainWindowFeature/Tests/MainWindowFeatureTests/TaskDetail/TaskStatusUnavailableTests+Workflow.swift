import HfCommon
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - Fresh workflow eligibility

extension TaskStatusUnavailableTests {
    @Test func givenSnapshotWithoutWorkflowFields_whenLatestListingBlocksTerminal_thenRetainedActionRefuses() {
        // given
        let fixtures = TaskDetailVMTests.Fixtures()
        let snapshot = TaskDetailVMTests().task(status: "completed")
        fixtures.detailBox.value = snapshot
        fixtures.statusReadProvider.value = { _ in .init(revision: 1, task: snapshot) }
        fixtures.taskProvider.value = { _ in self.workflowListing(snapshot, status: "running") }
        let harness = TaskDetailVMTests().makeSUT(chrome: .standalone, fixtures: fixtures)
        harness.sut.didAppear()
        // when
        harness.sut.didTapTakeover()
        // then
        #expect(harness.sut.latestActionTask()?.status == .completed)
        #expect(!WorkflowNodePresentation.allowsTerminal(harness.sut.latestActionTask()))
        verify(harness.useCase).beginTakeover(taskID: .any).called(0)
        harness.sut.didDisappear()
    }

    @Test func givenTakeoverConfirmation_whenLatestListingReturnsToRunning_thenFreshWorkflowGuardRefuses() async throws {
        // given
        let fixtures = TaskDetailVMTests.Fixtures()
        let snapshot = TaskDetailVMTests().task(status: "completed")
        let treeStatus = TaskDetailVMTests.Box("completed")
        fixtures.detailBox.value = snapshot
        fixtures.statusReadProvider.value = { _ in .init(revision: 1, task: snapshot) }
        fixtures.taskProvider.value = { _ in self.workflowListing(snapshot, status: treeStatus.value) }
        let harness = TaskDetailVMTests().makeSUT(chrome: .standalone, fixtures: fixtures)
        var event: ViewEvent?
        let subscription = harness.sut.objectDidPublishViewEvent.publisher.sink { event = $0 }
        harness.sut.didAppear()
        harness.sut.didTapTakeover()
        await waitUntil { event?.dialog != nil }
        let dialog = try #require(event?.dialog)
        // when
        treeStatus.value = "running"
        dialog.actions.first?.action()
        // then
        verify(harness.useCase).beginTakeover(taskID: .any).called(0)
        withExtendedLifetime(subscription) {}
        harness.sut.didDisappear()
    }

    private func workflowListing(_ snapshot: TaskInfo, status: String) -> TaskInfo {
        var raw = snapshot.raw
        raw["workflow_run_id"] = .string("workflow")
        raw["workflow_tree_status"] = .string(status)
        raw["workflow_tree_settling"] = .bool(false)
        return TaskInfo(.object(raw))!
    }
}
