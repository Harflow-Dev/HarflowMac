import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowOrchestratorConversationTests

struct WorkflowOrchestratorConversationTests {
    private func task(_ id: String, run: String = "run", role: String = "orchestrator", minute: Int, status: String = "completed") throws -> TaskInfo {
        try #require(TaskInfo(.object([
            "task_id": .string(id), "backend": .string("codex"), "session_id": .string("same-session"),
            "workflow_run_id": .string(run), "workflow_role": .string(role),
            "status": .string(status), "started_at": .string("2026-10-04T00:\(String(format: "%02d", minute)):00Z")
        ])))
    }

    @Test func givenSameSessionDecisionsAcrossRuns_whenHistoryResolved_thenOnlySameRunSessionCombines() throws {
        // given
        let tasks = try [task("b", minute: 2, status: "running"), task("worker", role: "node", minute: 1),
                         task("a", minute: 0), task("other", run: "other", minute: 1)]
        // when
        let members = try #require(WorkflowOrchestratorConversation.members(containing: "b", in: tasks))
        let representative = try #require(WorkflowOrchestratorConversation.representative(members))
        // then
        #expect(members.map(\.taskID) == ["a", "b"])
        #expect(representative.taskID == "a")
        #expect(representative.status.isRunning)
        #expect(WorkflowOrchestratorConversation.members(containing: "worker", in: tasks)?.count == 1)
    }

    @Test func givenTerminalWorkflowStillSettling_whenMessageEligibilityChecked_thenDirectMessagesRemainBlocked() throws {
        // given
        var raw = try task("node", role: "node", minute: 0).raw
        raw["workflow_status"] = .string("failed")
        raw["workflow_settling"] = .bool(true)
        // when / then
        #expect(WorkflowNodePresentation.blocksDirectMessages(try #require(TaskInfo(.object(raw)))))
        raw["workflow_settling"] = .bool(false)
        #expect(!WorkflowNodePresentation.blocksDirectMessages(try #require(TaskInfo(.object(raw)))))
    }
}

extension WorkflowOrchestratorConversationTests {
    @Test func givenSameNodeWithDifferentOrMissingHarnessSessions_whenGrouped_thenExecutionsStaySeparate() throws {
        // given
        let tasks = try (0 ..< 4).map { index in
            var raw: [String: JSONValue] = ["task_id": .string("attempt-\(index)"), "backend": .string("codex"),
                "workflow_run_id": .string("run"), "workflow_role": .string("node"), "workflow_node_id": .string("plan")]
            if index < 2 { raw["session_id"] = .string("session-\(index)") }
            if index > 0 { raw["parent_task_id"] = .string("attempt-\(index - 1)") }
            return try #require(TaskInfo(.object(raw)))
        }
        // when
        let conversations = WorkflowOrchestratorConversation.conversations(tasks)
        // then
        #expect(conversations.count == 4)
        #expect(conversations.allSatisfy { $0.members.count == 1 })
    }

    @Test func givenMatchingSessionIDOnDifferentHarnesses_whenGrouped_thenExecutionsStaySeparate() throws {
        // given
        let tasks = try ["claude", "codex"].map { backend in
            try #require(TaskInfo(.object(["task_id": .string(backend), "backend": .string(backend), "session_id": .string("same-id"),
                "workflow_run_id": .string("run"), "workflow_role": .string("orchestrator")])))
        }
        // when / then
        #expect(WorkflowOrchestratorConversation.conversations(tasks).count == 2)
    }
}
