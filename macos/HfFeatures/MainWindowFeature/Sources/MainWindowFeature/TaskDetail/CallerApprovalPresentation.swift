import Foundation
import MonitorCore

enum CallerApprovalPresentation {
    static func refusalMessage(_ reason: CallerApprovalResponseReason) -> String {
        switch reason {
        case .notCurrent:
            "The request changed or is no longer current. This response did not change it. Refresh to review the current action."
        case .alreadyAnswered:
            "This request already has an answer. This response did not change it."
        case .settled:
            "This request has already settled. This response did not change it."
        case .expired:
            "The request's deadline has passed. This response did not change it."
        case .ownershipLost:
            "No new decision was applied. The request owner is gone; Harflow may have invalidated the request."
        case .unauthorized:
            "The engine refused this response from the current caller context. This response did not change the request."
        case .unsupported:
            "This engine does not support this response. The request was not changed. Respond through the owning caller's MCP or CLI."
        case .callerUndecidable:
            "The engine could not determine the caller context. The request was not changed and is read-only here. "
                + "Respond through the owning caller's MCP or CLI."
        case .incomplete:
            "The complete action is unavailable. The request was not changed. Refresh to read the full action before responding."
        }
    }

    static func priority(_ request: CallerApprovalRequest) -> Int {
        if request.text("delivery") == "delivery_unknown" { return 1 }
        if request.text("disposition") == "pending" || ["reserved", "sending"].contains(request.text("delivery")) { return 0 }
        return 2
    }

    static func orderedBefore(_ lhs: CallerApprovalRequest, _ rhs: CallerApprovalRequest) -> Bool {
        let leftPriority = priority(lhs)
        let rightPriority = priority(rhs)
        if leftPriority != rightPriority { return leftPriority < rightPriority }
        let leftTime = lhs.raw["created_at"]?.doubleValue ?? 0
        let rightTime = rhs.raw["created_at"]?.doubleValue ?? 0
        return leftTime == rightTime ? lhs.id < rhs.id : leftTime < rightTime
    }

    static func decisionSummary(_ request: CallerApprovalRequest) -> [String] {
        let original = request.text("decision")
        let effective = request.text("effective_decision")
        let delivered = request.text("delivered_decision")
        var values: [String] = []
        if !original.isEmpty { values.append("Recorded decision: \(original)") }
        if !effective.isEmpty, effective != original { values.append("Effective decision: \(effective)") }
        if !delivered.isEmpty, delivered != original { values.append("Delivered decision: \(delivered)") }
        return values
    }
}
