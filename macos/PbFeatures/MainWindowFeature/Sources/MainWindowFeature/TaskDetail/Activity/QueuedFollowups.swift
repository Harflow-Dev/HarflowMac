import Foundation
import MonitorCore

// MARK: - QueuedFollowups

extension PendingMessage {
    /// Bubbles for the task's `queued_followups` ledger, in queue order. A missing field, an
    /// `unavailable` ledger or a malformed item yields nothing for it. Consumed and cancelled items
    /// carry no text (metadata only), so their bubbles describe the outcome instead.
    static func queuedFollowups(snapshot: TaskInfo?) -> [PendingMessage] {
        guard let ledger = snapshot?.raw["queued_followups"]?.objectValue,
              ledger["state"]?.stringValue == "available" else { return [] }
        let items = (ledger["items"]?.arrayValue ?? []).compactMap { value -> (Int, PendingMessage)? in
            guard let id = value["id"]?.stringValue, let status = value["status"]?.stringValue else { return nil }
            let text = value["text"]?.stringValue ?? ""
            let reason = value["reason"]?.stringValue
            let successor = value["successor_task_id"]?.stringValue
            let seq = value["seq"]?.intValue ?? Int.max
            let bubble: PendingMessage
            switch status {
            case "queued", "reserved":
                bubble = PendingMessage(id: "followup-" + id, text: text, caption: "Queued for next continuation")
            case "consumed":
                bubble = PendingMessage(
                    id: "followup-" + id, text: "Included verbatim in that task's prompt.",
                    caption: "Sent to " + (successor ?? "a continuation"), isPending: false, successorTaskID: successor)
            case "cancelled":
                bubble = PendingMessage(id: "followup-" + id, text: "Cancelled before it was sent.", caption: "Cancelled", isPending: false)
            case "undeliverable":
                bubble = PendingMessage(id: "followup-" + id, text: text, caption: "Undeliverable — " + (reason ?? "no reason recorded"), isPending: false)
            case "delivery_unknown":
                bubble = PendingMessage(id: "followup-" + id, text: text, caption: "Delivery unknown — " + (reason ?? "no reason recorded"), isPending: false)
            default:
                return nil
            }
            return (seq, bubble)
        }
        return items.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
