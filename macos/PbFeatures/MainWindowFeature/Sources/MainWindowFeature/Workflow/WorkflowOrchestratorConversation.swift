import Foundation
import MonitorCore

// MARK: - WorkflowOrchestratorConversation

/// Fresh decision sessions belong to one inspectable orchestrator conversation per run.
enum WorkflowOrchestratorConversation {
    static func members(containing id: String, in tasks: [TaskInfo]) -> [TaskInfo]? {
        guard let selected = tasks.first(where: { $0.taskID == id }),
              selected.raw["workflow_role"]?.stringValue == "orchestrator",
              let runID = selected.raw["workflow_run_id"]?.stringValue else { return nil }
        return tasks.filter {
            $0.raw["workflow_run_id"]?.stringValue == runID && $0.raw["workflow_role"]?.stringValue == "orchestrator"
        }
.sorted {
            if $0.startedAt != $1.startedAt { return ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
            return $0.taskID < $1.taskID
        }
    }

    static func representative(_ members: [TaskInfo]) -> TaskInfo? {
        guard let first = members.first, let current = members.last else { return nil }
        var raw = current.raw
        raw["task_id"] = .string(first.taskID)
        raw["started_at"] = first.raw["started_at"]
        return TaskInfo(.object(raw))
    }
}
