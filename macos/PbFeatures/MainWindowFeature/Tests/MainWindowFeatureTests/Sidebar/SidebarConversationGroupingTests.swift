import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - Session grouping characterization

@Suite struct SidebarConversationGroupingTests {
    @Test func givenMixedSessionMetadata_whenIndexed_thenLegacyMemberBoundariesAndOrderArePreserved() throws {
        // given
        var tasks: [TaskInfo] = []
        for index in 0 ..< 128 {
            var raw: [String: JSONValue] = [
                "task_id": .string("task-\(index)"), "backend": .string(index % 11 == 0 ? "unknown" : "codex"),
                "status": .string(index % 2 == 0 ? "running" : "completed"),
                "started_at": .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_800_000_000 + Double(index))))
            ]
            if index > 0 { raw["parent_task_id"] = .string("task-\(index - 1)") }
            if index % 3 != 0 { raw["workflow_run_id"] = .string(index % 2 == 0 ? "run-a" : "run-b") }
            if index % 5 != 0 { raw["session_id"] = .string(index % 7 == 0 ? "other" : "shared") }
            if index % 4 == 0 { raw["workflow_session_owner_run_id"] = .string("owner") }
            if index % 6 == 0 { raw["group"] = .string("parallel") }
            let roles = ["orchestrator", "builder", "node", "", "worker"]
            raw["workflow_role"] = .string(roles[index % roles.count])
            if index % 3 == 0 { raw["workflow_node_id"] = .string("node") }
            tasks.append(try #require(TaskInfo(.object(raw))))
        }
        // when
        let workflow = SidebarConversationGrouping(tasks, fallbackToConversation: false)
        let groups = SidebarConversationGrouping(tasks, fallbackToConversation: true)
        // then
        for task in tasks {
            let legacy = WorkflowOrchestratorConversation.members(containing: task.taskID, in: tasks)
            #expect(workflow.membersByTask[task.taskID] == legacy ?? [task])
            #expect(groups.membersByTask[task.taskID] == legacy ?? Lineage.conversation(containing: task.taskID, in: tasks)?.members ?? [task])
        }
        #expect(groups.conversations == WorkflowOrchestratorConversation.conversations(tasks))
    }
}
