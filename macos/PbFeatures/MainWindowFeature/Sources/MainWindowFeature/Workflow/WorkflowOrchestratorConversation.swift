import Foundation
import MonitorCore

// MARK: - WorkflowOrchestratorConversation

/// Workflow and parallel histories merge only when they share an actual harness session.
enum WorkflowOrchestratorConversation {
    static func members(containing id: String, in tasks: [TaskInfo]) -> [TaskInfo]? {
        guard let selected = tasks.first(where: { $0.taskID == id }) else { return nil }
        let lineage = Lineage.conversation(containing: id, in: tasks)?.members ?? [selected]
        let runID = selected.raw["workflow_run_id"]?.stringValue
        let ownerID = selected.raw["workflow_session_owner_run_id"]?.stringValue ?? runID
        guard runID != nil || lineage.contains(where: { $0.group != nil }) else { return nil }
        guard let session = selected.sessionID, !session.isEmpty, selected.backend != "unknown" else { return [selected] }
        let role = selected.raw["workflow_role"]?.stringValue ?? (selected.raw["workflow_builder"]?.boolValue == true ? "builder" : "")
        let nodeID = selected.raw["workflow_node_id"]?.stringValue
        let candidates: [TaskInfo]
        if let runID {
            guard ["orchestrator", "builder", "node"].contains(role), role != "node" || nodeID != nil else { return [selected] }
            candidates = tasks.filter {
                let otherRole = $0.raw["workflow_role"]?.stringValue ?? ($0.raw["workflow_builder"]?.boolValue == true ? "builder" : "")
                let otherOwner = $0.raw["workflow_session_owner_run_id"]?.stringValue ?? $0.raw["workflow_run_id"]?.stringValue
                return (role == "orchestrator" ? otherOwner == ownerID : $0.raw["workflow_run_id"]?.stringValue == runID) && otherRole == role
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

    /// Resolve ancestry and harness buckets once. Resolving each member independently rebuilt
    /// every ancestry component for every record in a large Parallel group.
    static func conversations(_ tasks: [TaskInfo]) -> [Conversation] {
        let canonical = Lineage.conversations(tasks)
        var lineageByID: [String: Conversation] = [:]
        var hasGroup: Set<String> = []
        var buckets: [HarnessKey: [TaskInfo]] = [:]
        let firstByID = Dictionary(tasks.map { ($0.taskID, $0) }, uniquingKeysWith: { first, _ in first })
        for conversation in canonical {
            if conversation.members.contains(where: { $0.group != nil }) { hasGroup.insert(conversation.id) }
            for member in conversation.members {
                lineageByID[member.taskID] = conversation
                if let session = member.sessionID, !session.isEmpty, member.backend != "unknown" {
                    buckets[.lineage(conversation.id, session, member.backend), default: []].append(member)
                }
            }
        }
        for task in tasks {
            guard let key = workflowKey(task) else { continue }
            buckets[key, default: []].append(task)
        }
        for key in buckets.keys { buckets[key]?.sort(by: oldestFirst) }
        var seen: Set<String> = []
        return tasks.compactMap { task in
            let selected = firstByID[task.taskID] ?? task
            let lineage = lineageByID[selected.taskID] ?? Conversation(members: [selected])
            let members = indexedMembers(selected, lineage: lineage, hasGroup: hasGroup.contains(lineage.id), buckets: buckets)
            guard let first = members.first, seen.insert(first.taskID).inserted else { return nil }
            return Conversation(members: members)
        }
    }

    private static func indexedMembers(_ selected: TaskInfo, lineage: Conversation, hasGroup: Bool,
                                       buckets: [HarnessKey: [TaskInfo]]) -> [TaskInfo] {
        if selected.raw["workflow_run_id"]?.stringValue == nil, !hasGroup { return lineage.members }
        guard let session = selected.sessionID, !session.isEmpty, selected.backend != "unknown" else { return [selected] }
        if selected.raw["workflow_run_id"]?.stringValue != nil {
            return workflowKey(selected).flatMap { buckets[$0] } ?? [selected]
        }
        return buckets[.lineage(lineage.id, session, selected.backend)] ?? [selected]
    }

    private enum HarnessKey: Hashable {
        case lineage(String, String, String)
        case orchestrator(String, String, String)
        case builder(String, String, String)
        case node(String, String, String, String)
    }

    private static func workflowKey(_ task: TaskInfo) -> HarnessKey? {
        guard let session = task.sessionID, !session.isEmpty, task.backend != "unknown" else { return nil }
        let role = task.raw["workflow_role"]?.stringValue ?? (task.raw["workflow_builder"]?.boolValue == true ? "builder" : "")
        let runID = task.raw["workflow_run_id"]?.stringValue
        let owner = task.raw["workflow_session_owner_run_id"]?.stringValue ?? runID
        switch role {
        case "orchestrator": return owner.map { .orchestrator($0, session, task.backend) }
        case "builder": return runID.map { .builder($0, session, task.backend) }
        case "node":
            guard let runID, let nodeID = task.raw["workflow_node_id"]?.stringValue else { return nil }
            return .node(runID, nodeID, session, task.backend)
        default: return nil
        }
    }

    private static func oldestFirst(_ lhs: TaskInfo, _ rhs: TaskInfo) -> Bool {
        if lhs.startedAt != rhs.startedAt { return (lhs.startedAt ?? .distantPast) < (rhs.startedAt ?? .distantPast) }
        return lhs.taskID < rhs.taskID
    }

    static func representative(_ members: [TaskInfo]) -> TaskInfo? {
        guard let first = members.first, let current = members.last else { return nil }
        var raw = current.raw
        raw["task_id"] = .string(first.taskID)
        raw["started_at"] = first.raw["started_at"]
        return TaskInfo(.object(raw))
    }
}
