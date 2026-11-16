import Foundation

// MARK: - MessagingStatus

/// Open messaging.v1 status. An unfamiliar status never grants cancellation.
public enum MessagingStatus: Equatable, Sendable {
    case queued, delivering, delivered, cancelled, undeliverable
    case unknown(String)

    public init(_ value: String) {
        switch value {
        case "queued": self = .queued
        case "delivering": self = .delivering
        case "delivered": self = .delivered
        case "cancelled": self = .cancelled
        case "undeliverable": self = .undeliverable
        default: self = .unknown(value)
        }
    }
}

// MARK: - MessagingRefusal

/// An explanatory note attached to a successful receipt; it never overrides status.
public struct MessagingRefusal: Equatable, Sendable {
    public let code: String
    public let message: String
}

// MARK: - MessagingSendReceipt

/// Engine-issued admission evidence. Acceptance does not establish delivery.
public struct MessagingSendReceipt: Equatable, Sendable {
    public let messageID: String
    public let sequence: Int
    public let status: MessagingStatus
    public let delivery: String
    public let taskID: String?
    public let workflowRunID: String?
    public let refusal: MessagingRefusal?
    public let targetSettled: Bool?
    public let targetStatus: String?
    public let note: String?
    public let successorTaskID: String?
    public let deliveryTaskID: String?
    public let deliveryStarted: Bool?
    public let reason: String?
    public let raw: [String: JSONValue]

    public init?(raw: [String: JSONValue]) {
        guard let id = raw["message_id"]?.stringValue, !id.isEmpty,
              let seq = raw["seq"]?.wireIntegerValue, seq > 0,
              let status = raw["status"]?.stringValue, !status.isEmpty,
              let delivery = raw["delivery"]?.stringValue, !delivery.isEmpty,
              MessagingWire.validOptionals(raw) else { return nil }
        if let value = raw["refusal"], value != .null {
            guard let object = value.objectValue,
                  let code = object["code"]?.stringValue, let message = object["message"]?.stringValue else { return nil }
            refusal = MessagingRefusal(code: code, message: message)
        } else { refusal = nil }
        messageID = id
        sequence = seq
        self.status = MessagingStatus(status)
        self.delivery = delivery
        taskID = raw["task_id"]?.stringValue
        workflowRunID = raw["workflow_run_id"]?.stringValue
        targetSettled = raw["target_settled"]?.boolValue
        targetStatus = raw["target_status"]?.stringValue
        note = raw["note"]?.stringValue
        successorTaskID = raw["successor_task_id"]?.stringValue
        deliveryTaskID = raw["delivery_task_id"]?.stringValue
        deliveryStarted = raw["delivery_started"]?.boolValue
        reason = raw["reason"]?.stringValue
        self.raw = raw
    }
}

// MARK: - MessagingCancelReceipt

/// The actual engine cancellation result, including unfamiliar read-only statuses.
public struct MessagingCancelReceipt: Equatable, Sendable {
    public let messageID: String
    public let status: MessagingStatus
    public let sequence: Int?
    public let delivery: String?
    public let reason: String?
    public let note: String?
    public let refusal: MessagingRefusal?
    public let taskID: String?
    public let workflowRunID: String?
    public let raw: [String: JSONValue]

    public init?(raw: [String: JSONValue]) {
        guard let id = raw["message_id"]?.stringValue, !id.isEmpty,
              let status = raw["status"]?.stringValue, !status.isEmpty,
              MessagingWire.validOptionals(raw) else { return nil }
        if let sequence = raw["seq"], sequence != .null, sequence.wireIntegerValue == nil { return nil }
        if let delivery = raw["delivery"], delivery != .null, delivery.stringValue == nil { return nil }
        if let value = raw["refusal"], value != .null {
            guard let object = value.objectValue,
                  let code = object["code"]?.stringValue, let message = object["message"]?.stringValue else { return nil }
            refusal = MessagingRefusal(code: code, message: message)
        } else { refusal = nil }
        sequence = raw["seq"]?.wireIntegerValue
        delivery = raw["delivery"]?.stringValue
        reason = raw["reason"]?.stringValue
        note = raw["note"]?.stringValue
        messageID = id
        self.status = MessagingStatus(status)
        taskID = raw["task_id"]?.stringValue
        workflowRunID = raw["workflow_run_id"]?.stringValue
        self.raw = raw
    }
}

// MARK: - MessagingWire

private enum MessagingWire {
    static func validOptionals(_ raw: [String: JSONValue]) -> Bool {
        let strings = ["task_id", "workflow_run_id", "target_status", "note", "successor_task_id", "delivery_task_id", "reason"]
        for key in strings {
            if let value = raw[key], value != .null, value.stringValue == nil { return false }
        }
        for key in ["target_settled", "delivery_started"] {
            if let value = raw[key], value != .null, value.boolValue == nil { return false }
        }
        return true
    }
}
