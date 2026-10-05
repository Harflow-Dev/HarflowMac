import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbCommon
import PbTestUtilities
import Testing

extension SidebarVMTests {
    @Test func givenBuilderTasksAndRuns_whenListed_thenOnlyExecutionAppearsInHistory() async {
        // given
        let harness = makeSUT()
        harness.sut.workflowRuns = [SidebarWorkflowRun(raw: ["kind": .string("builder"), "workflow_run_id": .string("builder"),
            "status": .string("running"), "activations": .array([.object(["tasks": .array([.object(["task_id": .string("legacy")])])])])])]
        let builder = TaskInfo(.object(["task_id": .string("edit"), "backend": .string("codex"), "status": .string("running"),
            "workflow_builder": .bool(true)]))!
        harness.sut.didAppear()
        // when
        harness.tasksSubject.send([builder, task(id: "legacy"), task(id: "execution")])
        await waitUntil { harness.sut.runningRows.map(\.id) == ["execution"] }
        // then
        #expect(harness.sut.filteredWorkflowRuns().isEmpty)
        #expect(harness.sut.latestTasks.contains { $0.taskID == "execution" })
        harness.sut.didDisappear()
    }

    @Test func givenWorkflowHistory_whenBucketed_thenActiveAndDatedRunsShareTaskHistoryWithoutIDCollisions() async {
        // given
        let harness = makeSUT()
        let now = Date()
        harness.sut.currentDate = { now }
        harness.sut.workflowRuns = [
            SidebarWorkflowRun(raw: ["workflow_run_id": .string("same"), "name": .string("Paused flow"),
                                     "status": .string("paused"), "created_at": .number(now.timeIntervalSince1970)]),
            SidebarWorkflowRun(raw: ["workflow_run_id": .string("today"), "status": .string("completed"),
                                     "created_at": .number(now.timeIntervalSince1970)]),
            SidebarWorkflowRun(raw: ["workflow_run_id": .string("old"), "status": .string("completed"),
                                     "created_at": .number(now.addingTimeInterval(-172800).timeIntervalSince1970)])
        ]
        harness.sut.didAppear()
        // when
        harness.tasksSubject.send([task(id: "same", status: "running")])
        await waitUntil { harness.sut.sections.count == 3 }
        // then
        #expect(Set(harness.sut.items(in: .running).map(\.id)) == ["task:same", "workflow:same"])
        #expect(harness.sut.items(in: .today).map(\.id) == ["workflow:today"])
        #expect(harness.sut.items(in: .earlier).map(\.id) == ["workflow:old"])
        harness.sut.didDisappear()
    }

    @Test func givenSavedDefinitionsAndRunHistory_whenSearching_thenNamesAndRepositoryAreSearchable() {
        // given
        let harness = makeSUT()
        harness.sut.workflowDefinitions = [WorkflowRecord(raw: ["name": .string("ship-release")]), WorkflowRecord(raw: ["name": .string("code-review")])]
        harness.sut.workflowRuns = [SidebarWorkflowRun(raw: ["workflow_run_id": .string("run"), "name": .string("code-review"),
                                                           "repo_path": .string("/tmp/release"), "status": .string("needs_attention")])]
        // when
        harness.sut.didChangeSearchQuery("release")
        // then
        #expect(harness.sut.savedWorkflows.map(\.id) == ["ship-release"])
        #expect(harness.sut.items(in: .running).map(\.id) == ["workflow:run"])
        harness.sut.didChangeSearchQuery("absent")
        #expect(harness.sut.savedWorkflows.isEmpty)
        #expect(harness.sut.sections.isEmpty)
    }

    @Test func givenRepeatedAddActions_whenTapped_thenEachRequestsAFreshEditorIdentity() {
        // given
        var destinations: [MonitorDestination?] = []
        let harness = makeSUT(onSelect: { destinations.append($0) })
        // when
        harness.sut.didTapNewWorkflow()
        harness.sut.didTapNewWorkflow()
        // then
        #expect(destinations.count == 2)
        #expect(destinations[0] != destinations[1])
        #expect(destinations.allSatisfy { if case .newWorkflow = $0 { true } else { false } })
    }

    @Test func givenWorkflowPolling_whenSidebarDisappears_thenLateResponseCannotReplaceHistory() async {
        // given
        let useCase = SuspendedSidebarWorkflows()
        let harness = makeSUT(workflowUseCase: useCase)
        harness.sut.didAppear()
        harness.sut.didAppear()
        await waitUntil { useCase.continuation != nil }
        #expect(useCase.requests == 1)
        // when
        harness.sut.didDisappear()
        useCase.continuation?.resume(returning: SidebarWorkflowSnapshot(definitions: [["name": .string("late")]], runs: []))
        await waitUntil { useCase.returned }
        // then
        #expect(harness.sut.workflowDefinitions.isEmpty)
        #expect(harness.sut.workflowPoll == nil)
    }

    @Test func givenWorkflowListFailure_whenPolling_thenExistingTaskHistoryRemainsVisible() async {
        // given
        let useCase = MockSidebarWorkflowUseCase()
        given(useCase).workflowSnapshot().willThrow(WorkflowSidebarError.unavailable)
        let harness = makeSUT(workflowUseCase: useCase)
        harness.sut.didAppear()
        harness.tasksSubject.send([task(id: "task", status: "running")])
        // when
        await waitUntil { harness.sut.workflowErrorMessage != nil && !harness.sut.sections.isEmpty }
        // then
        #expect(harness.sut.items(in: .running).map(\.id) == ["task:task"])
        #expect(harness.sut.workflowErrorMessage == "Workflow list unavailable")
        harness.sut.didDisappear()
    }

}

private enum WorkflowSidebarError: Error { case unavailable }

@MainActor
private final class SuspendedSidebarWorkflows: SidebarWorkflowUseCase {
    var continuation: CheckedContinuation<SidebarWorkflowSnapshot, Never>?
    var requests = 0
    var returned = false
    func workflowSnapshot() async throws -> SidebarWorkflowSnapshot {
        requests += 1
        let snapshot = await withCheckedContinuation { continuation = $0 }
        returned = true
        return snapshot
    }
}

extension SidebarVMTests {
    @Test func givenNestedRuns_whenExpanded_thenChildAppearsUnderParentAndSearchKeepsAncestor() {
        // given
        let harness = makeSUT()
        harness.sut.workflowRuns = [
            SidebarWorkflowRun(raw: ["workflow_run_id": .string("root"), "name": .string("Parent"), "status": .string("running")]),
            SidebarWorkflowRun(raw: ["workflow_run_id": .string("child"), "name": .string("Nested"), "status": .string("running"),
                                     "parent_workflow_run_id": .string("root")])
        ]
        harness.sut.expandedExecutionParents.insert("workflow:root")
        // when
        let items = harness.sut.workflowTreeItems(harness.sut.workflowRuns[0])
        harness.sut.didChangeSearchQuery("Nested")
        // then
        #expect(items.map(\.id) == ["workflow:root", "workflow:child"])
        if case .workflow(let child) = items.last { #expect(child.indent == 1) }
        #expect(harness.sut.filteredWorkflowRuns().map(\.id) == ["root", "child"])
        #expect(harness.sut.items(in: .running).map(\.id) == ["workflow:root", "workflow:child"])
    }
}

extension SidebarVMTests {
    @Test func givenNestedTask_whenRevealed_thenAllWorkflowAncestorsExpand() {
        // given
        let harness = makeSUT()
        harness.sut.workflowRuns = [
            SidebarWorkflowRun(raw: ["workflow_run_id": .string("root")]),
            SidebarWorkflowRun(raw: ["workflow_run_id": .string("child"), "parent_workflow_run_id": .string("root")]),
            SidebarWorkflowRun(raw: ["workflow_run_id": .string("grandchild"), "parent_workflow_run_id": .string("child")])
        ]
        harness.sut.latestTasks = [TaskInfo(.object(["task_id": .string("nested-task"), "workflow_run_id": .string("grandchild")]))!]
        // when
        harness.sut.expandExecutionParent(of: "nested-task")
        // then
        #expect(harness.sut.expandedExecutionParents == ["workflow:root", "workflow:child", "workflow:grandchild"])
    }
}
