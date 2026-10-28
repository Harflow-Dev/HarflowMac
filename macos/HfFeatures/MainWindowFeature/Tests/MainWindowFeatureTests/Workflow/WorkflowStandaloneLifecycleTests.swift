import Foundation
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowStandaloneLifecycleTests

@MainActor @Suite(.serialized) struct WorkflowStandaloneLifecycleTests {
    @Test func givenSelectedDecision_whenChoosingHistoryAndHiding_thenOnlyChosenActivityHoldsLeases() async throws {
        // given
        let vm = WorkflowPreview.make(run: true)
        let tests = ParallelVMTests()
        let harness = tests.makeSUT()
        vm.parallel = harness.sut
        let firstTask = tests.task(id: "first-task")
        let secondTask = tests.task(id: "second-task")
        harness.tasksBox.value = [firstTask.taskID: firstTask, secondTask.taskID: secondTask]
        var raw = try #require(vm.selectedRun?.raw)
        raw["activations"] = .array([decision("first", taskID: firstTask.taskID, status: "completed"),
                                    decision("second", taskID: secondTask.taskID, status: "running")])
        vm.selectedRun = WorkflowRunModel(raw: raw)
        vm.selectedNodeID = WorkflowStandalone.orchestratorID
        vm.setRunGraphVisible(true)
        await vm.sidebarTask?.value
        harness.tasksSubject.send([firstTask, secondTask])
        await waitUntil { vm.selectedActivity?.columns.count == 1 }
        let active = try #require(vm.selectedActivity)
        active.updateViewport(offset: 0, width: 320)
        await waitUntil { active.leasedMemberCount == 1 && active.isPresentationSettled }
        defer { vm.didDisappear() }
        #expect(vm.runSidebar.activationID == "second")
        #expect(active.columns.first?.task.taskID == secondTask.taskID)

        // when
        vm.selectActivation("first")
        await vm.sidebarTask?.value
        harness.tasksSubject.send([firstTask, secondTask])
        await waitUntil { vm.selectedActivity?.columns.count == 1 }
        let historical = try #require(vm.selectedActivity)
        historical.updateViewport(offset: 0, width: 320)
        await waitUntil { historical.leasedMemberCount == 1 && historical.isPresentationSettled }

        // then
        #expect(active.leasedMemberCount == 0)
        #expect(harness.releasedBox.value.contains(secondTask.taskID))
        #expect(historical.columns.first?.task.taskID == firstTask.taskID)
        raw["updated_at"] = .number(Date.now.timeIntervalSince1970)
        vm.selectedRun = WorkflowRunModel(raw: raw)
        await vm.sidebarTask?.value
        #expect(vm.runSidebar.activationID == "first")
        #expect(vm.selectedActivity === historical)
        vm.setRunGraphVisible(false)
        #expect(historical.leasedMemberCount == 0)
        vm.setRunGraphVisible(true)
        harness.tasksSubject.send([firstTask, secondTask])
        historical.updateViewport(offset: 0, width: 320)
        await waitUntil { historical.leasedMemberCount == 1 && historical.isPresentationSettled }
        #expect(vm.runSidebar.activationID == "first")
    }

    private func decision(_ id: String, taskID: String, status: String) -> JSONValue {
        .object(["id": .string(id), "node_id": .string("implementation"), "role": .string("orchestrator"),
                 "status": .string(status), "tasks": .array([.object(["task_id": .string(taskID), "status": .string(status)])])])
    }
}
