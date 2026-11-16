import HfRepository
import MonitorCore

// MARK: - WorkMessageOutcome

/// Describes the engine's delivery evidence without turning an uncertain launch into a queue claim.
enum WorkMessageOutcome {
    static func describe(_ result: [String: JSONValue]) -> String {
        let parts = [result["refusal"]?["message"]?.stringValue, advisoryNote(result), result["reason"]?.stringValue]
        var distinct: [String] = []
        for part in parts.compactMap(\.self) where !part.isEmpty && !distinct.contains(part) { distinct.append(part) }
        let explanation = distinct.isEmpty ? nil : distinct.joined(separator: "\n")
        switch result["status"]?.stringValue {
        case "queued":
            return explanation.map { "Queued — " + $0 } ?? "Queued — not yet delivered."
        case "undeliverable":
            return explanation.map { "Undeliverable — " + $0 } ?? "The message could not be delivered."
        case "delivering":
            return explanation ?? "Delivery is in progress."
        case "delivered":
            return explanation ?? "Message delivered."
        case "cancelled":
            return explanation ?? "Queued message cancelled."
        default:
            return explanation ?? "Message delivery status is unavailable."
        }
    }

    /// Only the standalone settled queue advisory has no drawn copy. Ambiguous or unsafe
    /// receipts retain their engine note; no prose is interpreted as authority.
    static func advisoryNote(_ result: [String: JSONValue]) -> String? {
        let standalone = result["task_id"]?.stringValue != nil
            && result["workflow_run_id"] == nil && result["workflow_id"] == nil
            && result["node_id"] == nil && result["delivery_task_id"] == nil
            && result["workflow_node_id"] == nil && result["workflow_role"] == nil
        let settledQueue = result["status"]?.stringValue == "queued"
            && result["delivery"]?.stringValue == "queue" && result["target_settled"] == .bool(true)
            && result["refusal"] == nil && result["reason"] == nil
        return standalone && settledQueue ? nil : result["note"]?.stringValue
    }

    static func notice(_ result: [String: JSONValue]) -> String? {
        guard result["refusal"] != nil || result["status"]?.stringValue == "undeliverable" else { return nil }
        return describe(result)
    }
}

extension WorkMessageOutcome {
    /// A deterministic phase line from the current task ledger; this never requests focus.
    static func ledger(_ raw: [String: JSONValue]) -> String? {
        let states = QueuedMessageState.project(raw: raw, source: WorkMessageQueue.source(raw))
        switch states.last?.state {
        case .delivering, .delivered:
            guard let last = states.last else { return nil }
            return describe(last.raw)
        case .cancelled: return "Queued message cancelled."
        default: return nil
        }
    }

    static func cancellation(_ attempt: MessagingSubmissionAttempt, messageID: String) -> String {
        guard case .cancel(let result) = attempt.outcome else { return "Cancellation could not be confirmed." }
        switch result {
        case .receipt(let receipt):
            guard receipt.messageID == messageID else { return "Cancellation could not be confirmed." }
            return describe(receipt.raw)
        case .refused(let error): return error.message
        case .unconfirmed: return "Cancellation could not be confirmed. The message may still be queued."
        case .messagingUnsupported: return "This engine does not support queued messages."
        case .notDispatched: return "Cancellation was not sent."
        }
    }
}

// MARK: - Submission outcome presentation

extension WorkMessageOutcome {
    static func submission(_ attempt: MessagingSubmissionAttempt) -> String? {
        guard case .send(let result) = attempt.outcome else { return nil }
        switch result {
        case .receipt(let receipt): return describe(receipt.raw)
        case .refused(let error): return error.message
        case .unconfirmed: return "Sending could not be confirmed. The message may already have been queued."
        case .messagingUnsupported: return "This engine does not support queued messages."
        case .notDispatched: return "The message was not sent. Your draft has been kept."
        }
    }
}
