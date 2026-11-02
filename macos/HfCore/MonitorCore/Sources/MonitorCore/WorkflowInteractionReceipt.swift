import Foundation

// MARK: - WorkflowInteractionReceipt

/// The engine's durable winner for one workflow interaction.
public struct WorkflowInteractionReceipt: Equatable, Sendable {
    public let interactionID: String
    public let workflowRunID: String
    public let action: String
    public let answer: String
    public let answeredBy: CallerApprovalOwner
    public let answeredAt: Double
    /// True when the persisted answer is a bounded excerpt.
    public let answerTruncated: Bool

    /// Rejects incomplete receipts and unknown responders rather than attributing an answer.
    public init?(_ value: JSONValue) {
        guard let object = value.objectValue,
              let id = object["interaction_id"]?.stringValue, !id.isEmpty,
              let run = object["workflow_run_id"]?.stringValue, !run.isEmpty,
              let action = object["action"]?.stringValue, !action.isEmpty,
              let answer = object["answer"]?.stringValue,
              let responder = object["answered_by"]?.stringValue.flatMap(CallerApprovalOwner.init(rawValue:)),
              let timestamp = object["answered_at"]?.doubleValue, timestamp.isFinite else { return nil }
        interactionID = id
        workflowRunID = run
        self.action = action
        self.answer = answer
        answeredBy = responder
        answeredAt = timestamp
        answerTruncated = object["answer_truncated"]?.boolValue == true
    }
}

public extension ToolError {
    /// A lost first-answer race, retaining the exact persisted winning response.
    var workflowInteractionWinner: WorkflowInteractionReceipt? {
        guard refusalCode == "interaction_already_answered" || refusalData?["code"]?.stringValue == "interaction_already_answered",
              let receipt = refusalData?["interaction"] else { return nil }
        return WorkflowInteractionReceipt(receipt)
    }
}
