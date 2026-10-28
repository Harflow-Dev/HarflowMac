import Foundation

// MARK: - ActivityFeedSnapshot

/// Immutable background-prepared render identity. Unchanged rows retain their opaque tokens;
/// unchanged snapshots retain the same object, so the native surface never compares history payloads.
final class ActivityFeedSnapshot: Equatable, Sendable {
    let rows: [ActivityRow]
    let ids: [String]
    let tokens: [String: UUID]

    private init(rows: [ActivityRow], tokens: [String: UUID]) {
        self.rows = rows
        self.ids = rows.map(\.id)
        self.tokens = tokens
    }

    static func == (lhs: ActivityFeedSnapshot, rhs: ActivityFeedSnapshot) -> Bool { lhs === rhs }

    /// Called by presentation workers, where payload comparison stays off the main actor.
    static func preparing(_ rows: [ActivityRow], previous: ActivityFeedSnapshot?) -> ActivityFeedSnapshot {
        let old = Dictionary(previous?.rows.map { ($0.id, $0) } ?? [], uniquingKeysWith: { _, last in last })
        var tokens: [String: UUID] = [:]
        for row in rows {
            tokens[row.id] = old[row.id] == row ? previous?.tokens[row.id] ?? UUID() : UUID()
        }
        if let previous, previous.ids == rows.map(\.id), previous.tokens == tokens { return previous }
        return ActivityFeedSnapshot(rows: rows, tokens: tokens)
    }
}
