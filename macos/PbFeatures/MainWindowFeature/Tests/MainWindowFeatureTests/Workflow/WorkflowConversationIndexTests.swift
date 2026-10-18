import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

struct WorkflowConversationIndexTests {
    @Test func indexedGroupingPreservesReferenceAcrossMixedAuthorityAndMalformedAncestry() throws {
        var tasks: [TaskInfo] = []
        for index in 0 ..< 48 {
            var raw: [String: JSONValue] = ["task_id": .string("task-\(index)"),
                "backend": .string(index % 11 == 0 ? "unknown" : (index % 3 == 0 ? "claude" : "codex")),
                "started_at": .string("2026-10-04T00:\(String(format: "%02d", index % 12)):00Z")]
            if index % 7 != 0 { raw["session_id"] = .string(index % 13 == 0 ? "" : "session-\(index % 3)") }
            if index % 4 != 0 { raw["parent_task_id"] = .string("task-\(index - 1)") }
            if index % 5 == 0 { raw["group"] = .string("parallel") }
            if index % 3 != 0 {
                raw["workflow_run_id"] = .string("run-\(index % 2)")
                raw["workflow_role"] = .string(["orchestrator", "builder", "node", "invalid"][index % 4])
                if index % 6 != 0 { raw["workflow_node_id"] = .string("node-\(index % 2)") }
                if index % 9 == 0 { raw["workflow_session_owner_run_id"] = .string("run-0") }
            }
            tasks.append(try #require(TaskInfo(.object(raw))))
        }
        var cyclic = tasks[0].raw
        cyclic["parent_task_id"] = .string("task-1")
        tasks[0] = try #require(TaskInfo(.object(cyclic)))
        for input in [tasks, Array(tasks.reversed()), Array(tasks.prefix(20))] {
            var seen: Set<String> = []
            let reference = input.compactMap { task -> Conversation? in
                let members = WorkflowOrchestratorConversation.members(containing: task.taskID, in: input)
                    ?? Lineage.conversation(containing: task.taskID, in: input)?.members ?? [task]
                guard let first = members.first, seen.insert(first.taskID).inserted else { return nil }
                return Conversation(members: members)
            }
            #expect(WorkflowOrchestratorConversation.conversations(input) == reference)
        }
    }
}
