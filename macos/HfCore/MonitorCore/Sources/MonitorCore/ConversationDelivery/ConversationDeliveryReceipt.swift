import Foundation

// MARK: - ConversationDeliverySendReceipt

/// The engine's admission receipt for one send.
///
/// A receipt is an admission record, not proof of consumption, and its status is a snapshot
/// taken at admission. Read the projection for later state.
public struct ConversationDeliverySendReceipt: Equatable, Sendable {
    /// Equals the request id of the send.
    public let messageID: String
    public let taskID: String
    public let conversationID: String
    /// The task the engine resolved the target to; this is the head task and may differ from `taskID`.
    public let resolvedTaskID: String?
    public let status: ConversationDeliveryMessage.Status?
    public let delivery: ConversationDeliveryMessage.Delivery?
    public let sequence: Int?
    public let workflowRunID: String?
    public let activationID: String?
    /// The original result object, including additive fields.
    public let raw: [String: JSONValue]

    /// A non-null workflow identity on a receipt for a plain task target is an identity mismatch.
    fileprivate static func hasWorkflowIdentity(_ raw: [String: JSONValue]) -> Bool {
        ["workflow_run_id", "activation_id"].contains { raw[$0].map { $0 != .null } ?? false }
    }

    /// Decodes a receipt and verifies every identity against the request that produced it.
    /// Conditional fields may be absent and additive fields are tolerated.
    init?(raw: [String: JSONValue], matching request: ConversationDeliverySendRequest) {
        guard raw["contract"]?.stringValue == ConversationDeliveryWire.contract,
              let messageID = raw.deliveryString("message_id"), messageID == request.requestIDText,
              let taskID = raw.deliveryString("task_id"), taskID == request.target.taskID,
              let conversationID = raw.deliveryString("conversation_id"),
              conversationID == request.witness.conversationID else { return nil }
        switch request.target {
        case .task:
            guard !Self.hasWorkflowIdentity(raw) else { return nil }
        case .workflowActivation(let run, let activation, _):
            guard raw.deliveryString("workflow_run_id") == run, raw.deliveryString("activation_id") == activation
            else { return nil }
        }
        for key in ["resolved_task_id", "status", "delivery"] {
            if let value = raw[key], value.stringValue == nil { return nil }
        }
        if let value = raw["sequence"], value.wireIntegerValue == nil { return nil }
        self.messageID = messageID
        self.taskID = taskID
        self.conversationID = conversationID
        resolvedTaskID = raw.deliveryString("resolved_task_id")
        status = raw.deliveryString("status").map { .init(rawValue: $0) }
        delivery = raw.deliveryString("delivery").map { .init(rawValue: $0) }
        sequence = raw.deliveryInt("sequence")
        workflowRunID = raw.deliveryString("workflow_run_id")
        activationID = raw.deliveryString("activation_id")
        self.raw = raw
    }
}

// MARK: - ConversationDeliveryControlReceipt

/// The engine's receipt for one cancel or promote operation.
///
/// A receipt is a control record, not proof of consumption, and its status is a snapshot.
/// Read the projection for later state.
public struct ConversationDeliveryControlReceipt: Equatable, Sendable {
    public let requestID: String
    public let messageRequestID: String
    public let operation: ConversationDeliveryControlOperation
    /// Standalone-task receipts report `cancelled` or `promoted`; workflow receipts carry none.
    public let status: String?
    public let taskID: String?
    public let conversationID: String?
    public let workflowRunID: String?
    public let activationID: String?
    /// The head task the control resolved to; this may differ from the target task.
    public let targetTaskID: String?
    public let turnID: String?
    public let generation: Int?
    public let ledgerEpoch: Int?
    /// The original result object, including additive fields.
    public let raw: [String: JSONValue]

    /// Decodes a receipt and verifies every identity against the request that produced it.
    init?(raw: [String: JSONValue], matching request: ConversationDeliveryControlRequest) {
        guard raw["contract"]?.stringValue == ConversationDeliveryWire.contract,
              raw.deliveryString("operation") == request.operation.rawValue else { return nil }
        let inner: [String: JSONValue]
        switch request.target {
        case .task:
            guard !ConversationDeliverySendReceipt.hasWorkflowIdentity(raw),
                  raw.deliveryString("request_id") == request.requestIDText,
                  raw.deliveryString("message_id") == request.messageRequestIDText,
                  raw.deliveryString("task_id") == request.target.taskID,
                  let control = raw["control"]?.objectValue,
                  control.deliveryString("request_id") == request.requestIDText,
                  control.deliveryString("message_request_id") == request.messageRequestIDText else { return nil }
            inner = control
        case .workflowActivation(let run, let activation, _):
            guard let receipt = raw["receipt"]?.objectValue,
                  receipt.deliveryString("request_id") == request.requestIDText,
                  receipt.deliveryString("message_request_id") == request.messageRequestIDText,
                  raw.deliveryString("conversation_id") == request.witness.conversationID,
                  raw.deliveryString("workflow_run_id") == run,
                  raw.deliveryString("activation_id") == activation else { return nil }
            inner = receipt
        }
        for key in ["turn_id", "target_task_id"] {
            if let value = inner[key], value.stringValue == nil { return nil }
        }
        for key in ["generation", "ledger_epoch"] {
            if let value = inner[key], value.wireIntegerValue == nil { return nil }
        }
        requestID = request.requestIDText
        messageRequestID = request.messageRequestIDText
        operation = request.operation
        status = raw.deliveryString("status")
        taskID = raw.deliveryString("task_id")
        conversationID = raw.deliveryString("conversation_id")
        workflowRunID = raw.deliveryString("workflow_run_id")
        activationID = raw.deliveryString("activation_id")
        targetTaskID = inner.deliveryString("target_task_id")
        turnID = inner.deliveryString("turn_id")
        generation = inner.deliveryInt("generation")
        ledgerEpoch = inner.deliveryInt("ledger_epoch")
        self.raw = raw
    }
}
