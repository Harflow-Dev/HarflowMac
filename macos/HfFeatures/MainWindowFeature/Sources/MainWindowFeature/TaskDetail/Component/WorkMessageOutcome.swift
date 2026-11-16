import HfRepository
import MonitorCore

// MARK: - WorkMessageOutcome

/// Describes the engine's delivery evidence without turning an uncertain launch into a queue claim.
enum WorkMessageOutcome {
    static func describe(_ result: [String: JSONValue]) -> String {
        let explanation = result["refusal"]?["message"]?.stringValue ?? result["reason"]?.stringValue
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
        case .delivering: return "Delivery is in progress."
        case .delivered: return "Message delivered."
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
