import Foundation

// MARK: - CallerApprovalRequest validation

/// Shared eligibility and confirmation rules for answering a caller approval from the Monitor. The
/// task view and Needs you apply the same checks, so they live with the request type.
public extension CallerApprovalRequest {
    /// Still awaiting a decision: pending, undelivered and with no decision or system rejection yet.
    var isAwaitingDecision: Bool {
        text("disposition") == "pending" && text("delivery") == "pending"
            && text("decision").isEmpty && text("effective_decision").isEmpty
            && text("system_rejection").isEmpty && text("decided_by").isEmpty
    }

    /// Not settled in any way the card must show as finished.
    var isVisuallyPending: Bool {
        !["decided", "expired", "system_rejected", "invalidated", "cancelled", "unsupported"].contains(text("disposition"))
            && text("decision").isEmpty && text("effective_decision").isEmpty
            && text("decided_by").isEmpty && text("system_rejection").isEmpty
    }

    /// Every enumerated field holds a value this app understands; unknown wire values are never actionable.
    var hasKnownState: Bool {
        ["pending", "decided", "expired", "system_rejected", "invalidated", "cancelled", "unsupported"].contains(text("disposition"))
            && ["pending", "reserved", "sending", "sent", "delivery_unknown", "failed"].contains(text("delivery"))
            && ["unknown", "succeeded", "failed", "not_observed"].contains(text("execution_outcome"))
            && optionalEnum("decided_by", ["", "caller", "harflow"])
            && optionalEnum("responder", ["", "caller", "monitor"])
            && ["decision", "effective_decision", "delivered_decision"].allSatisfy { optionalEnum($0, ["", "approve", "reject"]) }
            && (raw["system_rejection"] == nil || raw["system_rejection"] == .null || raw["system_rejection"]?.stringValue != nil)
    }

    private func optionalEnum(_ key: String, _ values: Set<String>) -> Bool {
        guard let value = raw[key], value != .null else { return true }
        guard let text = value.stringValue else { return false }
        return values.contains(text)
    }

    /// Carries every identity field the engine needs to recheck the response.
    var hasValidIdentity: Bool {
        !id.isEmpty && !taskID.isEmpty && !digest.isEmpty && (raw["owner_revision"]?.intValue ?? 0) > 0 && !text("generation").isEmpty
    }

    /// The same request at the same action, revision, generation and owner.
    func isSameCurrent(as other: CallerApprovalRequest) -> Bool {
        id == other.id && taskID == other.taskID && digest == other.digest && revision == other.revision
            && raw["generation"] == other.raw["generation"] && raw["interaction_owner"] == other.raw["interaction_owner"]
    }

    /// Whether `response` proves that `decision` was recorded for this exact request.
    func isConfirmedBy(_ response: CallerApprovalRequest, decision: String) -> Bool {
        let responder = response.raw["responder"]
        let responderOmitted = responder == nil || responder == .null
        return response.id == id && response.taskID == taskID && response.digest == digest
            && response.raw["generation"] == raw["generation"]
            && response.raw["interaction_owner"] == raw["interaction_owner"]
            && (response.revision ?? 0) > (revision ?? 0) && response.hasValidIdentity
            && response.complete && response.hasKnownState && response.raw["action"] == raw["action"]
            && response.text("decision") == decision && response.text("decided_by") == "caller"
            && response.text("delivery") != "pending" && (responder?.stringValue == "monitor" || responderOmitted)
    }
}
