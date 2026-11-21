import Foundation
import HfRepository
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

    static func canRefresh(_ outcome: ApprovalResponseOutcome) -> Bool {
        if case .refused(let error, _) = outcome {
            return error.callerApprovalWinner == nil && error.callerApprovalResponseReason != .expired && error.callerApprovalResponseReason != .settled
        }
        return false
    }

    static func outcomeLines(_ outcome: ApprovalResponseOutcome) -> [String] {
        switch outcome {
        case .uncertain: return [ApprovalResponseOutcome.uncertainMessage]
        case .busy: return ["An approval response is already in progress."]
        case .recorded(let request): return CallerApprovalPresentation.resultLines(request)
        case .refused(let error, let current):
            if let current, current.text("disposition") == "expired" { return CallerApprovalPresentation.resultLines(current) }
            if let winner = error.callerApprovalWinner {
                let channel = winner.answeredBy == .caller ? "Already answered by the caller" : "Answered in Harflow"
                return [channel, Date(timeIntervalSince1970: winner.answeredAt).formatted(date: .abbreviated, time: .shortened),
                        "Recorded decision: " + winner.decision]
            }
            return [error.callerApprovalResponseReason.map(CallerApprovalPresentation.refusalMessage) ?? error.message]
        }
    }

    /// The cards whose decision controls move to a pinned bar: every card offering controls for a request awaiting a
    /// decision, in card order. When a request settles its bar goes and the next card's bar is unaffected.
    static func pinnedBars(_ cards: [CallerApprovalCardModel]) -> [CallerApprovalCardModel] {
        cards.filter { $0.pending && $0.showsDecisionControls }
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

    static func resultLines(_ request: CallerApprovalRequest) -> [String] {
        var lines = decisionSummary(request)
        if request.text("disposition") == "expired" {
            lines.insert("Expired", at: 0)
            if request.raw["expiry_rejection"]?.boolValue == true, request.text("delivery") == "sent",
               request.text("effective_decision") == "reject", request.text("delivered_decision") == "reject" {
                lines.append("Harflow rejected the request when it expired.")
            } else { lines.append(refusalMessage(.expired)) }
        }
        lines.append("Delivery: " + request.text("delivery"))
        lines.append("Observed execution: " + request.text("execution_outcome"))
        if request.text("delivery") == "delivery_unknown" { lines.append("Delivery is unknown. The decision will not be retried.") }
        if request.text("disposition") == "expired" { lines.append("It can't be approved later. After the task finishes, continue it in a new session.") }
        return lines
    }

    static func decisionSummary(_ request: CallerApprovalRequest) -> [String] {
        let original = request.text("decision")
        let effective = request.text("effective_decision")
        let delivered = request.text("delivered_decision")
        var values: [String] = []
        if let responder = request.answeredBy, !original.isEmpty {
            let label = responder == .monitor ? "Answered in Harflow" : "Answered by the caller"
            let timestamp = request.answeredAt.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) }
            values.append(label + (timestamp.map { " · " + $0 } ?? ""))
        }
        if !original.isEmpty { values.append("Recorded decision: \(original)") }
        if !effective.isEmpty, effective != original { values.append("Effective decision: \(effective)") }
        if !delivered.isEmpty, delivered != original { values.append("Delivered decision: \(delivered)") }
        return values
    }
}

struct CallerApprovalReveal: Equatable, Sendable {
    let requestID: String
    let token: UUID
}

// MARK: - Approval response confirmation

extension CallerApprovalController {
    static func confirmsResponse(_ response: CallerApprovalRequest, for request: CallerApprovalRequest, decision: String) -> Bool {
        request.isConfirmedBy(response, decision: decision)
    }
}
