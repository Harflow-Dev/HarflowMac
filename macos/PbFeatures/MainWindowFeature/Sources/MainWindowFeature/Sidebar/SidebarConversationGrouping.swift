import Foundation
import MonitorCore

// MARK: - SidebarConversationGrouping

/// Indexes candidate sessions once while preserving the existing, sometimes asymmetric,
/// per-task workflow grouping rules and first-encounter conversation ordering.
struct SidebarConversationGrouping {
    private struct Key: Hashable {
        let scope: String
        let role: String
        let node: String?
        let backend: String
        let session: String
    }

    let membersByTask: [String: [TaskInfo]]
    private let orderedTaskIDs: [String]

    init(_ tasks: [TaskInfo], fallbackToConversation: Bool) {
        let index = ConversationIndex(tasks)
        var native: [Key: [TaskInfo]] = [:]
        var lineage: [Key: [TaskInfo]] = [:]
        for task in tasks {
            if Task.isCancelled { break }
            guard let session = task.sessionID, !session.isEmpty, task.backend != "unknown" else { continue }
            let conversationKey = Key(scope: index.conversationID(of: task.taskID), role: "", node: nil,
                                      backend: task.backend, session: session)
            lineage[conversationKey, default: []].append(task)
            if let key = Self.nativeKey(task, session: session) { native[key, default: []].append(task) }
        }
        native = native.mapValues(Self.ordered)
        lineage = lineage.mapValues(Self.ordered)
        var members: [String: [TaskInfo]] = [:]
        for task in tasks {
            if Task.isCancelled { break }
            let conversation = index.conversation(containing: task.taskID)
            let hasWorkflow = task.raw["workflow_run_id"]?.stringValue != nil
            guard hasWorkflow || conversation?.members.contains(where: { $0.group != nil }) == true else {
                members[task.taskID] = fallbackToConversation ? conversation?.members ?? [task] : [task]
                continue
            }
            guard let session = task.sessionID, !session.isEmpty, task.backend != "unknown" else {
                members[task.taskID] = [task]
                continue
            }
            if hasWorkflow {
                members[task.taskID] = Self.nativeKey(task, session: session).flatMap { native[$0] } ?? [task]
            } else {
                let key = Key(scope: index.conversationID(of: task.taskID), role: "", node: nil, backend: task.backend, session: session)
                members[task.taskID] = lineage[key] ?? [task]
            }
        }
        self.membersByTask = members
        self.orderedTaskIDs = tasks.map(\.taskID)
    }

    private static func nativeKey(_ task: TaskInfo, session: String) -> Key? {
        let role = task.raw["workflow_role"]?.stringValue ?? (task.raw["workflow_builder"]?.boolValue == true ? "builder" : "")
        let node = task.raw["workflow_node_id"]?.stringValue
        guard ["orchestrator", "builder", "node"].contains(role), role != "node" || node != nil else { return nil }
        let run = task.raw["workflow_run_id"]?.stringValue
        guard let scope = role == "orchestrator" ? task.raw["workflow_session_owner_run_id"]?.stringValue ?? run : run else { return nil }
        return Key(scope: scope, role: role, node: role == "node" ? node : nil, backend: task.backend, session: session)
    }

    private static func ordered(_ tasks: [TaskInfo]) -> [TaskInfo] {
        tasks.sorted {
            if $0.startedAt != $1.startedAt { return ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
            return $0.taskID < $1.taskID
        }
    }

    var conversations: [Conversation] {
        var seen: Set<String> = []
        return orderedTaskIDs.compactMap { id in
            guard let members = membersByTask[id], let first = members.first, seen.insert(first.taskID).inserted else { return nil }
            return Conversation(members: members)
        }
    }
}
