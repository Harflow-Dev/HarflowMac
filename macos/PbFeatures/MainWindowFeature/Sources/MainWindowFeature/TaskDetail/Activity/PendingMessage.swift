import Foundation
import MonitorCore

struct PendingMessage: Identifiable, Equatable, Sendable {
    let id: String
    let text: String

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
        }
    }
}
