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
        #expect(harness.sut.workflowErrorMessage?.hasPrefix("Workflow list unavailable:") == true)
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
        #expect(items.map(\.id) == ["workflow:root", "workflow-shortcut:root:child"])
        if case .workflowShortcut(let child, _) = items.last { #expect(child.indent == 1); #expect(child.guides == [.last]) }
        #expect(harness.sut.filteredWorkflowRuns().map(\.id) == ["root", "child"])
        #expect(Set(harness.sut.items(in: .running).map(\.id)) == ["workflow:root", "workflow:child", "workflow-shortcut:root:child"])
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

extension SidebarVMTests {
    @Test func givenMalformedWorkflowHeadersAndTaskOwners_whenListed_thenCannotBecomeSelectableRunRows() {
        // given
        let harness = makeSUT()
        harness.sut.mergeWorkflowHeaders([
            ["workflow_run_id": .string("valid"), "status": .string("running")],
            ["workflow_run_id": .string("workflow:bad"), "status": .string("running")],
            ["workflow_run_id": .string(""), "status": .string("running")]
        ])
        harness.sut.latestTasks = [
            TaskInfo(.object(["task_id": .string("empty-owner"), "workflow_run_id": .string("")]))!,
            TaskInfo(.object(["task_id": .string("invalid-owner"), "workflow_run_id": .string("bad owner")]))!
        ]
        // when
        let rows = harness.sut.filteredWorkflowRuns()
        // then
        #expect(rows.map(\.id) == ["valid"])
        #expect(harness.sut.workflowRuns.map(\.id) == ["valid"])
        #expect(harness.sut.workflowTaskOwners.isEmpty)
        #expect(harness.sut.executionParent(of: "empty-owner") == nil)
        #expect(harness.sut.executionParent(of: "invalid-owner") == nil)
    }
}

extension SidebarVMTests {
    @Test func givenChildInvocation_whenParentExpanded_thenShortcutIsSiblingOfParentTasks() throws {
        // given
        let harness = makeSUT()
        let parent = SidebarWorkflowRun(raw: ["workflow_run_id": .string("parent"), "status": .string("running")])
        let child = SidebarWorkflowRun(raw: ["workflow_run_id": .string("child"), "name": .string("Review"),
            "parent_link": .object(["workflow_run_id": .string("parent"), "execution_id": .string("invoke")])])
        harness.sut.workflowRuns = [parent, child]
        harness.sut.latestTasks = [try #require(TaskInfo(.object(["task_id": .string("invoker"), "workflow_run_id": .string("parent"),
            "workflow_execution_id": .string("invoke"), "status": .string("running")])))]
        harness.sut.expandedExecutionParents.insert("workflow:parent")
        // when
        let items = harness.sut.workflowTreeItems(parent)
        // then
        #expect(items.map(\.id) == ["workflow:parent", "task:invoker", "workflow-shortcut:parent:child"])
        if case .workflowShortcut(let row, _) = items[2] { #expect(row.indent == 1); #expect(row.guides == [.last]); #expect(!row.hasChildren) }
    }

    @Test func givenCanonicalChild_whenBucketed_thenStandaloneRootExpandsItsOwnTasks() throws {
        // given
        let harness = makeSUT()
        harness.sut.workflowRuns = [
            SidebarWorkflowRun(raw: ["workflow_run_id": .string("parent")]),
            SidebarWorkflowRun(raw: ["workflow_run_id": .string("child"), "parent_workflow_run_id": .string("parent")])
        ]
        harness.sut.latestTasks = [try #require(TaskInfo(.object(["task_id": .string("worker"), "workflow_run_id": .string("child")])))]
        harness.sut.expandedExecutionParents.insert("workflow:child")
        // when
        let sections = harness.sut.bucketedSections(trees: [], groups: [], forcedExpandedIDs: [])
        // then
        #expect(Set(sections.flatMap(\.items).map(\.id)) == ["workflow:parent", "workflow:child", "task:worker"])
    }
}

extension SidebarVMTests {
    @Test func givenFinishedInvokingTaskAndRunningChild_whenAliasSelected_thenBothEntriesHighlightActualRunningWorkflow() throws {
        // given
        let harness = makeSUT()
        let parent = SidebarWorkflowRun(raw: ["workflow_run_id": .string("parent"), "status": .string("running")])
        let child = SidebarWorkflowRun(raw: ["workflow_run_id": .string("child"), "status": .string("running"),
            "parent_link": .object(["workflow_run_id": .string("parent"), "execution_id": .string("invoke")])])
        harness.sut.workflowRuns = [parent, child]
        harness.sut.latestTasks = [try #require(TaskInfo(.object(["task_id": .string("invoker"), "workflow_run_id": .string("parent"),
            "workflow_execution_id": .string("invoke"), "status": .string("completed")])))]
        harness.sut.expandedExecutionParents.insert("workflow:parent")
        // when
        let items = harness.sut.bucketedSections(trees: [], groups: [], forcedExpandedIDs: []).flatMap(\.items)
        let alias = try #require(items.first { if case .workflowShortcut = $0 { return true }; return false })
        harness.sut.didSelect(alias.destination)
        // then
        #expect(alias.destination == .workflowRun("child"))
        #expect(items.filter { $0.isSelected(harness.sut.selection) }.map(\.id) == ["workflow:child", "workflow-shortcut:parent:child"])
        #expect(Set(items.map(\.id)).count == items.count)
        if case .workflowShortcut(let row, _) = alias { #expect(row.status == .running) }
        if let canonical = items.first(where: { $0.id == "workflow:child" }), case .workflow(let row) = canonical { #expect(row.status == .running) }
    }
}

extension SidebarVMTests {
    @Test func givenRootHeaderReferencesChildButHistoryOmitsIt_whenResolved_thenVisibleShortcutUsesUnknownThenActualChildStatus() async throws {
        // given
        let harness = makeSUT()
        let parent = SidebarWorkflowRun(raw: ["workflow_run_id": .string("parent"), "status": .string("running"),
            "child_invocations": .array([.object(["execution_id": .string("invoke"), "child_workflow_run_id": .string("child")])])])
        harness.sut.workflowRuns = [parent]
        harness.sut.latestTasks = [try #require(TaskInfo(.object(["task_id": .string("chat"), "workflow_run_id": .string("parent"),
            "workflow_role": .string("orchestrator"), "status": .string("completed")])))]
        harness.sut.expandedExecutionParents.insert("workflow:parent")
        // when
        await harness.sut.refreshChildInvocationHeaders()
        let preparing = harness.sut.workflowTreeItems(parent)
        harness.sut.mergeWorkflowHeaders([["workflow_run_id": .string("child"), "parent_workflow_run_id": .string("parent"),
            "name": .string("Child"), "status": .string("running")]])
        let running = harness.sut.workflowTreeItems(parent)
        // then
        #expect(preparing.map(\.id) == ["workflow:parent", "task:chat", "workflow-shortcut:parent:child"])
        if case .workflowShortcut(let row, _) = preparing[2] { #expect(row.status != .completed) }
        if case .workflowShortcut(let row, _) = running[2] { #expect(row.status == .running) }
        #expect(running[2].destination == .workflowRun("child"))
    }
}

extension SidebarVMTests {
    @Test func givenRecursiveChildRuns_whenExpanded_thenEachCanonicalRootOwnsOnlyImmediateNodesAndGuidedShortcuts() throws {
        // given
        let harness = makeSUT()
        harness.sut.workflowRuns = [
            SidebarWorkflowRun(raw: ["workflow_run_id": .string("parent"), "status": .string("running")]),
            SidebarWorkflowRun(raw: ["workflow_run_id": .string("child"), "status": .string("running"), "parent_workflow_run_id": .string("parent")]),
            SidebarWorkflowRun(raw: ["workflow_run_id": .string("grandchild"), "status": .string("running"), "parent_workflow_run_id": .string("child")])
        ]
        harness.sut.latestTasks = [try #require(TaskInfo(.object(["task_id": .string("worker"), "workflow_run_id": .string("child")])))]
        harness.sut.expandedExecutionParents = ["workflow:parent", "workflow:child", "workflow:grandchild"]
        // when
        let parentItems = harness.sut.workflowTreeItems(harness.sut.workflowRuns[0])
        let childItems = harness.sut.workflowTreeItems(harness.sut.workflowRuns[1])
        let all = harness.sut.bucketedSections(trees: [], groups: [], forcedExpandedIDs: []).flatMap(\.items)
        // then
        #expect(parentItems.map(\.id) == ["workflow:parent", "workflow-shortcut:parent:child"])
        #expect(childItems.map(\.id) == ["workflow:child", "task:worker", "workflow-shortcut:child:grandchild"])
        #expect(all.filter { if case .workflow = $0 { return true }; return false }.count == 3)
        #expect(Set(all.map(\.id)).count == all.count)
        if case .task(let row) = childItems[1] { #expect(row.guides == [.branch]) }
        if case .workflowShortcut(let row, _) = childItems[2] {
            #expect(row.guides == [.last])
            #expect(row.detailLabel == "Child workflow")
        }
        #expect(childItems[2].destination == .workflowRun("grandchild"))
    }
}

extension SidebarVMTests {
    @Test func givenChildOrchestratorSharingParentSession_whenCanonicalChildExpanded_thenItsOwnTaskRemainsUnderChildRoot() throws {
        // given
        let harness = makeSUT()
        let child = SidebarWorkflowRun(raw: ["workflow_run_id": .string("child"), "parent_workflow_run_id": .string("parent")])
        harness.sut.workflowRuns = [child]
        harness.sut.latestTasks = [try #require(TaskInfo(.object(["task_id": .string("child-chat"), "workflow_run_id": .string("child"),
            "workflow_session_owner_run_id": .string("parent"), "workflow_role": .string("orchestrator"), "session_id": .string("shared")])))]
        harness.sut.expandedExecutionParents.insert("workflow:child")
        // when
        let items = harness.sut.workflowTreeItems(child)
        // then
        #expect(items.map(\.id) == ["workflow:child", "task:child-chat"])
        #expect(harness.sut.workflowChildren("parent").isEmpty)
    }
}
