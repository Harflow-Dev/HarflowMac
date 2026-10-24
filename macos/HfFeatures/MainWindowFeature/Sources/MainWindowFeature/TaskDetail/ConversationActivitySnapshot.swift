import Foundation
import MonitorCore

// MARK: - ConversationActivitySnapshot

/// Immutable loaded detail activity and history inventory, captured before its leases end.
struct ConversationActivitySnapshot: Sendable {
    let conversation: Conversation
    let input: TaskDetailTimelineInput?
    let presentation: TaskDetailTimelinePresentation?
    let title: String
    let loadedMembers: Set<String>
    let oldestSequences: [String: Int]
    let session: String?
    let cursor: String?
    let inventoryComplete: Bool
    let inventoryIncomplete: Bool
    let inventoryError: String?
    let paginationRevision: Int
}

extension TaskDetailVM {
    func exportConversationActivity() -> ConversationActivitySnapshot? {
        guard !conversationMembers.isEmpty else { return nil }
        let boundaries = Dictionary(conversationMembers.compactMap { member in
            useCase.events(for: member.taskID).first.map { (member.taskID, $0.seq) }
        }, uniquingKeysWith: { first, _ in first })
        return ConversationActivitySnapshot(conversation: Conversation(members: conversationMembers),
            input: appliedTimelineInput, presentation: appliedTimelinePresentation, title: title,
            loadedMembers: loadedActivityMembers, oldestSequences: boundaries,
            session: conversationMembers.last?.sessionID, cursor: conversationCursor,
            inventoryComplete: conversationHistoryResolved && !conversationHasMore,
            inventoryIncomplete: conversationHistoryIncomplete, inventoryError: conversationError,
            paginationRevision: activityPaginationRevision)
    }
}
