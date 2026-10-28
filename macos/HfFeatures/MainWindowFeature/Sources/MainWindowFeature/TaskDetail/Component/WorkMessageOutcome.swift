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
        default:
            return explanation ?? "Immediate delivery requested."
        }
    }

    static func notice(_ result: [String: JSONValue]) -> String? {
        guard result["refusal"] != nil || result["status"]?.stringValue == "undeliverable" else { return nil }
        return describe(result)
    }
}
