import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - Execution hierarchy tests

extension SidebarVMTests {
    @Test func givenSingleTaskGroup_whenExpansionRequested_thenNoChildRowsOrExpansion() {
        // given
        let harness = makeSUT()
        harness.sut.latestTasks = [task(id: "only", group: "Solo")]
        harness.sut.conversationIndex = ConversationIndex(harness.sut.latestTasks)
        harness.sut.recompute()
        // when
        harness.sut.didToggleExpansion(taskID: "group:Solo")
        harness.sut.didSelect(.task("only"))
        // then
        #expect(!harness.sut.isExecutionParentExpanded("group:Solo"))
        #expect(harness.sut.sections.flatMap(\.items).map(\.id) == ["group:Solo"])
    }

    @Test func givenWorkflowMetadataBeforePoll_whenListed_thenOneParentAndExpandableChildren() throws {
        // given
        let harness = makeSUT()
        let child = try #require(TaskInfo(.object(["task_id": .string("worker"), "backend": .string("codex"),
                                                   "status": .string("running"), "workflow_run_id": .string("run"),
                                                   "workflow_name": .string("Review"), "workflow_status": .string("running")])))
        harness.sut.latestTasks = [child, task(id: "followup", parentTaskID: "worker")]
        harness.sut.conversationIndex = ConversationIndex(harness.sut.latestTasks)
        // when
        harness.sut.recompute()
        // then
        #expect(harness.sut.sections.flatMap(\.items).map(\.id) == ["workflow:run"])
        harness.sut.didToggleExpansion(taskID: "workflow:run")
        #expect(Set(harness.sut.sections.flatMap(\.items).map(\.id)) == ["workflow:run", "task:worker", "task:followup"])
        harness.sut.selectedBackend = "codex"
        harness.sut.recompute()
        #expect(harness.sut.sections.flatMap(\.items).contains { $0.id == "workflow:run" })
        #expect(harness.sut.isExecutionParentExpanded("workflow:run"))
    }

    @Test func givenCollapsedWorkflow_whenChildSelected_thenParentExpandsAndExactExecutionSelected() throws {
        // given
        let harness = makeSUT()
        let child = try #require(TaskInfo(.object(["task_id": .string("worker"), "workflow_run_id": .string("run"),
                                                   "workflow_status": .string("running")])))
        harness.sut.latestTasks = [child, task(id: "retry", parentTaskID: "worker")]
        harness.sut.conversationIndex = ConversationIndex(harness.sut.latestTasks)
        // when
        harness.sut.didSelect(.task("retry"))
        // then
        #expect(harness.sut.selection == .task("retry"))
        #expect(harness.sut.isExecutionParentExpanded("workflow:run"))
        #expect(harness.sut.sections.flatMap(\.items).contains { $0.id == "task:retry" })
    }

    @Test func givenParallelGroup_whenExpanded_thenMembersAppearOnlyUnderParent() {
        // given
        let harness = makeSUT()
        harness.sut.latestTasks = [task(id: "a", group: "Review"), task(id: "b", group: "Review")]
        harness.sut.conversationIndex = ConversationIndex(harness.sut.latestTasks)
        // when
        harness.sut.recompute()
        // then
        #expect(harness.sut.sections.flatMap(\.items).map(\.id) == ["group:Review"])
        harness.sut.didSelect(.task("b"))
        #expect(harness.sut.sections.flatMap(\.items).map(\.id).count == 3)
        #expect(harness.sut.selection == .task("b"))
    }
}

extension SidebarVMTests {
    @Test func givenMultipleOrchestratorDecisions_whenWorkflowExpanded_thenOneLogicalChildWithCurrentStatus() throws {
        // given
        let harness = makeSUT()
        let turns = try ["a", "b"].enumerated().map { index, id in
            try #require(TaskInfo(.object([
                "task_id": .string(id), "workflow_run_id": .string("run"), "workflow_role": .string("orchestrator"),
                "workflow_status": .string("running"), "status": .string(index == 0 ? "completed" : "running"),
                "started_at": .string("2026-10-04T00:0\(index):00Z")
            ])))
        }
        harness.sut.latestTasks = turns
        harness.sut.conversationIndex = ConversationIndex(turns)
        // when
        harness.sut.didSelect(.task("b"))
        harness.sut.recompute()
        // then
        #expect(harness.sut.workflowChildren("run").map(\.taskID) == ["a"])
        #expect(harness.sut.workflowChildren("run").first?.status.isRunning == true)
        #expect(harness.sut.selection == .task("a"))
        #expect(harness.sut.sections.flatMap(\.items).map(\.id) == ["workflow:run", "task:a"])
    }
}
