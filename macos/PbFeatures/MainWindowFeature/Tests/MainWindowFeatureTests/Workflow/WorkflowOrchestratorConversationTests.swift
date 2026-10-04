import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowOrchestratorConversationTests

struct WorkflowOrchestratorConversationTests {
    private func task(_ id: String, run: String = "run", role: String = "orchestrator", minute: Int, status: String = "completed") throws -> TaskInfo {
        try #require(TaskInfo(.object([
            "task_id": .string(id), "workflow_run_id": .string(run), "workflow_role": .string(role),
            "status": .string(status), "started_at": .string("2026-10-04T00:\(String(format: "%02d", minute)):00Z")
        ])))
    }

    @Test func givenFreshDecisionsAcrossRuns_whenLogicalHistoryResolved_thenOnlySameRunOrchestratorTurnsCombine() throws {
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
        #expect(WorkflowOrchestratorConversation.members(containing: "worker", in: tasks) == nil)
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
