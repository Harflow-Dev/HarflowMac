import MonitorCore

/// Only identities cross this boundary. Heavy presentations never participate in retention.
enum ParallelStateMigration {
    nonisolated static func mapping(previous: [Conversation], current: [Conversation], retained: Set<String>) -> [String: String] {
        var result: [String: String] = [:]
        var available = retained
        for conversation in current where available.contains(conversation.id) {
            result[conversation.id] = conversation.id
            available.remove(conversation.id)
        }
        var oldIDsByMember: [String: [String]] = [:]
        for conversation in previous where available.contains(conversation.id) {
            for member in conversation.members { oldIDsByMember[member.taskID, default: []].append(conversation.id) }
        }
        let rank = Dictionary(previous.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for conversation in current where result[conversation.id] == nil {
            let candidates = Set(conversation.members.flatMap { oldIDsByMember[$0.taskID] ?? [] }).intersection(available)
            guard let oldID = candidates.min(by: { (rank[$0] ?? .max) < (rank[$1] ?? .max) }) else { continue }
            result[conversation.id] = oldID
            available.remove(oldID)
        }
        return result
    }
}
