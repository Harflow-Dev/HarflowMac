import Foundation
import MonitorCore
import PbUI
import PbUtilities

// MARK: - ParallelLayout

/// The column-width rule (Monitor piece 12, Design point 3): columns fill the available width rather
/// than a fixed 900pt budget, so there is no empty band on the right when the window is wide — with a
/// 420pt reading-width floor, below which columns keep their old fixed width and the row scrolls horizontally
/// instead of squeezing further. A pure function so it is testable without a SwiftUI rendering
/// harness.
enum ParallelLayout {
    /// The width of the hairline `Divider` drawn after every column (`ParallelView`'s `ForEach`) —
    /// subtracted from `availableWidth` before dividing, so `memberCount` columns plus their dividers
    /// together account for the whole row rather than overflowing it by a few points.
    static let dividerWidth: CGFloat = 1
    static let minimumColumnWidth: CGFloat = 420

    static func columnWidth(memberCount: Int, availableWidth: CGFloat) -> CGFloat {
        let count = max(1, memberCount)
        let usableWidth = max(0, availableWidth - CGFloat(count) * dividerWidth)
        return max(minimumColumnWidth, usableWidth / CGFloat(count))
    }
}

// MARK: - ParallelLeaseOrder

enum ParallelLeaseOrder {
    nonisolated static func members(_ conversations: [Conversation]) -> [String] {
        let queues = conversations.map { $0.members.reversed().map(\.taskID) }
        var result: [String] = []
        for depth in 0 ..< (queues.map(\.count).max() ?? 0) {
            for queue in queues where depth < queue.count { result.append(queue[depth]) }
        }
        return result
    }
}

// MARK: - ParallelHeader

enum ParallelHeader {
    static func subtitle(_ conversations: [Conversation], startedAt: Date?) -> String {
        let first = conversations.map(\.first)
        let freedoms = Set(first.compactMap(\.freedom).map { AccessLabel.text(freedom: $0) }).sorted().joined(separator: ", ")
        let repos = Set(first.map { Format.repoName($0.repoPath) }).sorted().joined(separator: ", ")
        let count = conversations.count
        return "\(count) agent\(count == 1 ? "" : "s") · \(freedoms) · \(repos)"
            + (startedAt.map { " · started \(Format.time($0))" } ?? "")
    }
}

// MARK: - ParallelMembership

enum ParallelMembership {
    @MainActor static func extending(_ conversation: Conversation, states: [String: ParallelColumnUIState]) -> Conversation {
        let retained = states.values.first { state in state.inventoryMembers[conversation.current.taskID] != nil }
        let state = states[conversation.id] ?? retained
        guard state?.inventorySession == conversation.current.sessionID else { return conversation }
        let byID = Dictionary((Array(state?.inventoryMembers.values ?? [:].values) + conversation.members).map { ($0.taskID, $0) },
            uniquingKeysWith: { _, fresh in fresh })
        let inventory = Array(byID.values)
        let members = WorkflowOrchestratorConversation.members(containing: conversation.current.taskID, in: inventory)
            ?? Lineage.conversation(containing: conversation.current.taskID, in: inventory)?.members
        return members.map { Conversation(members: $0) } ?? conversation
    }

    static func conversations(tasks: [TaskInfo], group: [Conversation], workflowTaskIDs: [String]?, focusedTaskIDs: Set<String>?) -> [Conversation] {
        guard let workflowTaskIDs else { return WorkflowOrchestratorConversation.conversations(group.flatMap(\.members)) }
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskID, $0) })
        return WorkflowOrchestratorConversation.conversations(workflowTaskIDs.compactMap { byID[$0] }).filter { conversation in
            focusedTaskIDs.map { focus in conversation.members.contains { focus.contains($0.taskID) } } ?? true
        }
    }
}
