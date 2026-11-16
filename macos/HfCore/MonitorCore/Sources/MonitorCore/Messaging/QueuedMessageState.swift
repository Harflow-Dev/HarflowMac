import Foundation

// MARK: - QueuedMessageState

/// Status-first projection of engine ledger evidence, independent of submission attempts.
public struct QueuedMessageState: Equatable, Sendable, Identifiable {
    public enum Source: Equatable, Sendable {
        case standalone
        case workflowNode(taskID: String)
        case workflowRun
    }

    public enum State: Equatable, Sendable {
        case queued, delivering, uncertain, delivered, cancelled, undeliverable
        case unknown(String)
    }

    public let id: String
    public let sequence: Int
    public let source: Source
    public let state: State
    public let text: String?
    public let reason: String?
    public let refusal: MessagingRefusal?
    public let deliveryTargetTaskID: String?
    public let raw: [String: JSONValue]
    public var canCancel: Bool { state == .queued }
    public var isMetadataOnly: Bool { state == .delivered || state == .cancelled }

    /// Workflow-owned tasks never fall back to the standalone follow-up ledger.
    public static func project(raw: [String: JSONValue], source: Source) -> [Self] {
        let values: [JSONValue]
        if raw["messages"] != nil {
            values = raw["messages"]?.arrayValue ?? []
        } else if source == .standalone, raw["queued_followups"]?["state"]?.stringValue == "available" {
            values = raw["queued_followups"]?["items"]?.arrayValue ?? []
        } else { return [] }
        return values.compactMap { value in
            guard let object = value.objectValue,
                  let id = object["id"]?.stringValue, !id.isEmpty,
                  let status = object["status"]?.stringValue else { return nil }
            let reason = object["reason"]?.stringValue
            let state: State
            switch status {
            case "queued": state = .queued
            case "delivering": state = source == .standalone && reason != nil ? .uncertain : .delivering
            case "delivered": state = .delivered
            case "cancelled": state = .cancelled
            case "undeliverable": state = .undeliverable
            case "reserved" where source == .standalone: state = .delivering
            case "consumed" where source == .standalone: state = .delivered
            case "delivery_unknown" where source == .standalone: state = .uncertain
            default: state = .unknown(status)
            }
            let refusal: MessagingRefusal?
            if let code = object["refusal"]?["code"]?.stringValue,
               let message = object["refusal"]?["message"]?.stringValue {
                refusal = MessagingRefusal(code: code, message: message)
            } else { refusal = nil }
            return Self(id: id, sequence: object["seq"]?.wireIntegerValue ?? Int.max, source: source,
                        state: state, text: state == .delivered || state == .cancelled ? nil : object["text"]?.stringValue,
                        reason: reason, refusal: refusal,
                        deliveryTargetTaskID: object[source == .standalone ? "successor_task_id" : "delivery_task_id"]?.stringValue,
                        raw: object)
        }.sorted { $0.sequence == $1.sequence ? $0.id < $1.id : $0.sequence < $1.sequence }
    }
}
