import Foundation

// MARK: - MessagingOutcome

/// One invocation's evidence. Unconfirmed submissions must never be replayed automatically.
public enum MessagingOutcome<Receipt: Equatable & Sendable>: Equatable, Sendable {
    case receipt(Receipt)
    case messagingUnsupported
    case notDispatched(ConversationDeliveryNotDispatchedCause)
    case refused(MessagingSendError)
    case unconfirmed(ConversationDeliveryUncertainCause)
}

// MARK: - MessagingSendError

/// Typed engine errors retain their wording. No error code grants permission to retry.
public struct MessagingSendError: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case superseded, messageTooLarge, queueFull, other(String)
    }

    public let kind: Kind
    public let message: String
    public let data: [String: JSONValue]?
    /// Only structured engine evidence supplies an identity; prose is never parsed for routing.
    public var successorTaskID: String? { data?["successor_task_id"]?.stringValue }

    init(_ error: ConversationDeliveryEngineError) {
        switch error.code {
        case "superseded": kind = .superseded
        case "message_too_large": kind = .messageTooLarge
        case "queue_full": kind = .queueFull
        default: kind = .other(error.code)
        }
        message = error.message
        data = error.data
    }
}

// MARK: - CtlClient messaging.v1

public extension CtlClient {
    /// Additive typed adapter; raw send/sendNow callers migrate in the composer slice.
    func sendMessage(_ taskID: String, text: String, now: Bool = false) async -> MessagingOutcome<MessagingSendReceipt> {
        let options = ["--delivery=\(now ? "now" : "queue")", "--monitor"]
        return await messagingMutation("send", options: options, positionals: [taskID, text]) { raw in
            guard let receipt = MessagingSendReceipt(raw: raw),
                  receipt.delivery == (now ? "now" : "queue"),
                  receipt.taskID == taskID || (receipt.taskID == nil && receipt.workflowRunID.map(TaskPendingLaunchWire.isFullID) == true) else { return nil }
            return receipt
        }
    }

    /// Returns the engine's actual receipt; a timeout is not cancellation evidence.
    func cancelQueuedMessage(_ taskID: String, messageID: String) async -> MessagingOutcome<MessagingCancelReceipt> {
        await messagingMutation("cancel-message", options: ["--monitor"], positionals: [taskID, messageID]) { raw in
            guard let receipt = MessagingCancelReceipt(raw: raw), receipt.messageID == messageID,
                  receipt.taskID == taskID || (receipt.taskID == nil && receipt.workflowRunID.map(TaskPendingLaunchWire.isFullID) == true) else { return nil }
            return receipt
        }
    }
}

private extension CtlClient {
    func messagingMutation<Receipt: Equatable & Sendable>(
        _ command: String, options: [String], positionals: [String],
        receipt: ([String: JSONValue]) -> Receipt?
    ) async -> MessagingOutcome<Receipt> {
        let exchange = await conversationExchange(command: command, options: options, positionals: positionals,
                                                  timeout: Self.quickTimeout, requiredCapabilities: ["messaging.v1"])
        let classified: ConversationDeliveryOutcome<String, Receipt>
        switch exchange {
        case .notLaunched(.missingCapability): return .messagingUnsupported
        case .notLaunched(let cause): return .notDispatched(cause)
        case .launched(let output):
            classified = classifyConversationMutation(output, command: command, options: options,
                                                       request: command, timeout: Self.quickTimeout, receipt: receipt)
        }
        switch classified {
        case .accepted(let value): return .receipt(value)
        case .notDispatched(_, let cause): return .notDispatched(cause)
        case .engineError(_, let error): return .refused(MessagingSendError(error))
        case .uncertain(_, let cause): return .unconfirmed(cause)
        }
    }
}
