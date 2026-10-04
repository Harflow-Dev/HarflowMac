import Foundation
import MonitorCore

// MARK: - WorkflowOrchestratorConversation

/// Workflow and parallel histories merge only when they share an actual harness session.
enum WorkflowOrchestratorConversation {
    static func members(containing id: String, in tasks: [TaskInfo]) -> [TaskInfo]? {
        guard let selected = tasks.first(where: { $0.taskID == id }) else { return nil }
        let lineage = Lineage.conversation(containing: id, in: tasks)?.members ?? [selected]
        let runID = selected.raw["workflow_run_id"]?.stringValue
        guard runID != nil || lineage.contains(where: { $0.group != nil }) else { return nil }
        guard let session = selected.sessionID, !session.isEmpty, selected.backend != "unknown" else { return [selected] }
        let role = selected.raw["workflow_role"]?.stringValue ?? (selected.raw["workflow_builder"]?.boolValue == true ? "builder" : "")
        let nodeID = selected.raw["workflow_node_id"]?.stringValue
        let candidates: [TaskInfo]
        if let runID {
            guard ["orchestrator", "builder", "node"].contains(role), role != "node" || nodeID != nil else { return [selected] }
            candidates = tasks.filter {
                let otherRole = $0.raw["workflow_role"]?.stringValue ?? ($0.raw["workflow_builder"]?.boolValue == true ? "builder" : "")
                return $0.raw["workflow_run_id"]?.stringValue == runID && otherRole == role
                    && (role != "node" || $0.raw["workflow_node_id"]?.stringValue == nodeID)
            }
        } else {
            candidates = lineage
        }
        return candidates.filter { $0.sessionID == session && $0.backend == selected.backend }.sorted {
            if $0.startedAt != $1.startedAt { return ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
            return $0.taskID < $1.taskID
        }
    }

    static func conversations(_ tasks: [TaskInfo]) -> [Conversation] {
        var seen: Set<String> = []
        return tasks.compactMap { task in
            let members = members(containing: task.taskID, in: tasks)
                ?? Lineage.conversation(containing: task.taskID, in: tasks)?.members ?? [task]
            guard let first = members.first, seen.insert(first.taskID).inserted else { return nil }
            return Conversation(members: members)
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
