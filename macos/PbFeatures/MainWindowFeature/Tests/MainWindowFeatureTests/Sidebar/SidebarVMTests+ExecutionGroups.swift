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
                "backend": .string("codex"), "session_id": .string("shared-orchestrator"),
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

extension SidebarVMTests {
    @Test func givenSameSessionNodeResumes_whenExpanded_thenEachNodeSessionHasOneChild() throws {
        // given
        let harness = makeSUT()
        harness.sut.latestTasks = try (0 ..< 4).map { index in
            try #require(TaskInfo(.object([
                "task_id": .string("attempt-\(index)"), "workflow_run_id": .string("run"), "workflow_role": .string("node"),
                "backend": .string("codex"), "session_id": .string(index < 2 ? "plan-session" : "adjudicate-session"),
                "workflow_node_id": .string(index < 2 ? "plan" : "adjudicate"), "workflow_status": .string("running"),
                "started_at": .string("2026-10-04T00:0\(index):00Z"), "status": .string(index.isMultiple(of: 2) ? "completed" : "running")
            ])))
        }
        harness.sut.conversationIndex = ConversationIndex(harness.sut.latestTasks)
        // when
        harness.sut.didSelect(.task("attempt-3"))
        harness.sut.recompute()
        // then
        #expect(harness.sut.workflowChildren("run").map(\.taskID) == ["attempt-0", "attempt-2"])
        #expect(harness.sut.selection == .task("attempt-2"))
        #expect(Set(harness.sut.sections.flatMap(\.items).map(\.id)) == ["workflow:run", "task:attempt-0", "task:attempt-2"])
    }

    @Test func givenParallelMemberWithFollowup_whenExpanded_thenFollowupUsesOriginalLogicalRow() {
        // given
        let harness = makeSUT()
        harness.sut.latestTasks = [task(id: "a", group: "Review"), task(id: "b", group: "Review"),
                                  task(id: "a-followup", group: "Review", parentTaskID: "a")].map { task in
            var raw = task.raw
            raw["session_id"] = .string(task.taskID == "b" ? "session-b" : "session-a")
            return TaskInfo(.object(raw))!
        }
        harness.sut.conversationIndex = ConversationIndex(harness.sut.latestTasks)
        // when
        harness.sut.didToggleExpansion(taskID: "group:Review")
        harness.sut.didSelect(.task("a-followup"))
        harness.sut.recompute()
        // then
        #expect(harness.sut.selection == .task("a"))
        #expect(Set(harness.sut.sections.flatMap(\.items).map(\.id)) == ["group:Review", "task:a", "task:b"])
    }
}

extension SidebarVMTests {
    @Test(arguments: [true, false])
    func givenOneParallelLineage_whenSessionsDiffer_thenExpansionMatchesActualSessionCount(sameSession: Bool) throws {
        // given
        let harness = makeSUT()
        harness.sut.latestTasks = try ["first", "followup"].enumerated().map { index, id in
            var raw = task(id: id, group: "Sessions", parentTaskID: index == 0 ? nil : "first").raw
            raw["session_id"] = .string(sameSession ? "shared" : "fresh-\(index)")
            return try #require(TaskInfo(.object(raw)))
        }
        harness.sut.conversationIndex = ConversationIndex(harness.sut.latestTasks)
        harness.sut.recompute()
        let group = try #require(Lineage.sections(harness.sut.latestTasks).parallel.first)
        // when
        harness.sut.didToggleExpansion(taskID: group.id)
        // then
        #expect(harness.sut.groupConversations(group).count == (sameSession ? 1 : 2))
        #expect(harness.sut.isExecutionParentExpanded(group.id) == !sameSession)
        #expect(harness.sut.sections.flatMap(\.items).count == (sameSession ? 1 : 3))
        if !sameSession {
            #expect(harness.sut.executionParent(of: "followup") == group.id)
        }
    }
}
