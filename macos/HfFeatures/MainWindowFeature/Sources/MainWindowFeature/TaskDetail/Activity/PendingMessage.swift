import Foundation
import MonitorCore

/// One bubble in the activity tail for a message the caller has sent that is not yet an event in
/// the feed: a live-input message awaiting its pump ("Pending"), or a follow-up queued for a task's
/// next continuation and its later states (see `queuedFollowups`).
struct PendingMessage: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    var caption = "Pending"
    /// Whether the text reads as not yet sent (dimmed).
    var isPending = true
    /// The continuation a consumed follow-up went to; the bubble links to it.
    var successorTaskID: String?

    static func visible(snapshot: TaskInfo?, events: [TaskEvent]) -> [PendingMessage] {
        var delivered: Set<String> = []
        for event in events {
            guard let raw = JSONValue.parse(Data(event.rawLine.utf8))?.objectValue,
                  ["task_started", "user_message", "undelivered"].contains(raw["kind"]?.stringValue ?? "") else { continue }
            if let id = raw["message_id"]?.stringValue { delivered.insert(id) }
            delivered.formUnion(raw["message_ids"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        }
        var seen: Set<String> = []
        return (snapshot?.raw["pending_messages"]?.arrayValue ?? []).compactMap { value in
            guard value["status"]?.stringValue == "pending", let id = value["id"]?.stringValue,
                  let text = value["text"]?.stringValue, !delivered.contains(id),
                  !delivered.contains(value["delivery_id"]?.stringValue ?? id), seen.insert(id).inserted else { return nil }
            return PendingMessage(id: id, text: text)
        } + queuedFollowups(snapshot: snapshot)
    }
}
