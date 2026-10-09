import MonitorCore

// MARK: - SidebarGroupPresentation

/// Domain values accompany a complete, precomputed signature of the group row's visible content.
struct SidebarGroupPresentation: Equatable, Sendable {
    private struct Signature: Equatable, Sendable {
        let name: String
        let anyRunning: Bool
        let backends: [String]
        let count: Int
        let finished: Int
        let singleStatus: TaskStatus?
        let expanded: Bool
    }

    let group: ParallelGroup
    let conversations: [Conversation]
    let isExpanded: Bool
    private let signature: Signature

    var id: String { group.id }
    var name: String { group.name }

    init(group: ParallelGroup, conversations: [Conversation], isExpanded: Bool) {
        self.group = group
        self.conversations = conversations
        self.isExpanded = isExpanded
        self.signature = Signature(name: group.name, anyRunning: group.anyRunning,
                              backends: conversations.prefix(3).map(\.first.backend), count: conversations.count,
                              finished: conversations.filter(\.current.status.isTerminal).count,
                              singleStatus: conversations.count == 1 ? conversations.first?.current.status : nil,
                              expanded: conversations.count > 1 && isExpanded)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.signature == rhs.signature }
}
