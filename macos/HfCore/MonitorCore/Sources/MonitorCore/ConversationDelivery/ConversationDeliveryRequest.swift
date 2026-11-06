import Foundation

// MARK: - ConversationDeliveryWire

/// Wire constants and local validation rules shared by the `conversation_delivery_v1` adapters.
enum ConversationDeliveryWire {
    static let contract = "conversation_delivery_v1"
    static let maxTextBytes = 32 * 1024
    static let maxRequestBytes = 64 * 1024
    static let maxIdentifierBytes = 256
    /// `JSONValue` renders and decodes integers exactly only below 1e15.
    static let maxCounter = 999_999_999_999_999

    /// Non-empty, at most 256 UTF-8 bytes, no scalar below U+0020 (the engine's `identifier`).
    static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maxIdentifierBytes
            && !value.unicodeScalars.contains { $0.value < 0x20 }
    }

    /// Lowercase canonical hyphenated UUID text (the engine's `request_uuid`).
    static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    static func uuidText(_ value: UUID) -> String { value.uuidString.lowercased() }

    /// Empty or ASCII-whitespace-only text. Other blank-looking text is left to the engine.
    static func isBlank(_ text: String) -> Bool {
        text.utf8.allSatisfy { $0 == 0x20 || (0x09 ... 0x0D).contains($0) }
    }

    static func render(_ document: [String: JSONValue]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: JSONValue.object(document).foundationObject,
                                              options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw ConversationDeliveryRequestError.unrenderable
        }
    }

    static func counter(_ value: Int) -> JSONValue { .number(Double(value), isInteger: true) }
}

// MARK: - ConversationDeliveryRequestError

/// A local refusal raised while building a request value. No process was launched.
public enum ConversationDeliveryRequestError: Error, Equatable, Sendable {
    /// An identifier is empty, longer than 256 UTF-8 bytes, or contains a control character.
    case invalidIdentifier(field: String)
    /// A value that must be a lowercase canonical UUID is not one.
    case invalidUUID(field: String)
    /// A generation or ledger epoch is negative or beyond the exactly representable range.
    case invalidCounter(field: String)
    /// The text is empty or consists only of ASCII whitespace.
    case blankText
    /// The text exceeds 32 KiB in UTF-8.
    case textTooLarge(bytes: Int)
    /// The rendered request file exceeds 64 KiB, which JSON escaping can cause for valid text.
    case requestTooLarge(bytes: Int)
    /// The request document could not be rendered.
    case unrenderable
}

// MARK: - ConversationDeliveryWitness

/// The conversation witness (`expected`) a request is bound to.
///
/// A retry must resend the witness of the original request. Never replace it with a witness
/// read from a later projection.
public struct ConversationDeliveryWitness: Equatable, Sendable {
    public let conversationID: String
    public let headTaskID: String
    public let generation: Int
    public let turnID: String
    public let ledgerEpoch: Int

    /// Validates every field with the engine's local rules.
    public init(conversationID: String, headTaskID: String, generation: Int, turnID: String,
                ledgerEpoch: Int) throws {
        guard ConversationDeliveryWire.isCanonicalUUID(conversationID) else {
            throw ConversationDeliveryRequestError.invalidUUID(field: "conversation_id")
        }
        guard ConversationDeliveryWire.isIdentifier(headTaskID) else {
            throw ConversationDeliveryRequestError.invalidIdentifier(field: "head_task_id")
        }
        guard ConversationDeliveryWire.isIdentifier(turnID) else {
            throw ConversationDeliveryRequestError.invalidIdentifier(field: "turn_id")
        }
        guard (0 ... ConversationDeliveryWire.maxCounter).contains(generation) else {
            throw ConversationDeliveryRequestError.invalidCounter(field: "generation")
        }
        guard (0 ... ConversationDeliveryWire.maxCounter).contains(ledgerEpoch) else {
            throw ConversationDeliveryRequestError.invalidCounter(field: "ledger_epoch")
        }
        self.conversationID = conversationID
        self.headTaskID = headTaskID
        self.generation = generation
        self.turnID = turnID
        self.ledgerEpoch = ledgerEpoch
    }

    var document: JSONValue {
        .object([
            "conversation_id": .string(conversationID),
            "head_task_id": .string(headTaskID),
            "generation": ConversationDeliveryWire.counter(generation),
            "turn_id": .string(turnID),
            "ledger_epoch": ConversationDeliveryWire.counter(ledgerEpoch)
        ])
    }
}

// MARK: - ConversationDeliveryTarget

/// The exact message target. Only a complete task id is a valid target; a prefix refuses at send.
public enum ConversationDeliveryTarget: Equatable, Sendable {
    case task(taskID: String)
    case workflowActivation(workflowRunID: String, activationID: String, taskID: String)

    /// The task the request addresses.
    public var taskID: String {
        switch self {
        case .task(let taskID): return taskID
        case .workflowActivation(_, _, let taskID): return taskID
        }
    }

    func validate() throws {
        switch self {
        case .task(let taskID):
            try Self.require(taskID, "target.task_id")
        case .workflowActivation(let run, let activation, let taskID):
            try Self.require(run, "target.workflow_run_id")
            try Self.require(activation, "target.activation_id")
            try Self.require(taskID, "target.task_id")
        }
    }

    private static func require(_ value: String, _ field: String) throws {
        guard ConversationDeliveryWire.isIdentifier(value) else {
            throw ConversationDeliveryRequestError.invalidIdentifier(field: field)
        }
    }

    var document: JSONValue {
        switch self {
        case .task(let taskID):
            return .object(["kind": .string("task"), "task_id": .string(taskID)])
        case .workflowActivation(let run, let activation, let taskID):
            return .object(["kind": .string("workflow_activation"), "workflow_run_id": .string(run),
                            "activation_id": .string(activation), "task_id": .string(taskID)])
        }
    }
}

// MARK: - ConversationDeliveryMode

/// Requested delivery priority. `now` is a request, not a guarantee of immediate consumption.
public enum ConversationDeliveryMode: String, Equatable, Sendable {
    case queue, now
}

// MARK: - ConversationDeliverySendRequest

/// One immutable send intent and its rendered request bytes.
///
/// Building the value validates it locally and renders the document once. An explicit retry
/// passes the same value again and sends identical bytes. The initializer takes every stored
/// field, so a caller can rebuild an identical value after a restart; rendering is
/// deterministic. Text is never normalized.
public struct ConversationDeliverySendRequest: Equatable, Sendable {
    public let requestID: UUID
    public let witness: ConversationDeliveryWitness
    public let target: ConversationDeliveryTarget
    public let mode: ConversationDeliveryMode
    public let text: String
    /// The exact bytes written to the request file.
    public let body: Data

    /// The request id as sent on the wire: lowercase canonical UUID text.
    public var requestIDText: String { ConversationDeliveryWire.uuidText(requestID) }

    /// Throws `ConversationDeliveryRequestError` for input the engine would refuse locally.
    /// Blank-text screening covers only empty or ASCII-whitespace-only text; the engine decides
    /// every other case.
    public init(requestID: UUID, witness: ConversationDeliveryWitness, target: ConversationDeliveryTarget,
                mode: ConversationDeliveryMode, text: String) throws {
        try target.validate()
        guard !ConversationDeliveryWire.isBlank(text) else { throw ConversationDeliveryRequestError.blankText }
        let textBytes = text.utf8.count
        guard textBytes <= ConversationDeliveryWire.maxTextBytes else {
            throw ConversationDeliveryRequestError.textTooLarge(bytes: textBytes)
        }
        let body = try ConversationDeliveryWire.render([
            "contract": .string(ConversationDeliveryWire.contract),
            "request_id": .string(ConversationDeliveryWire.uuidText(requestID)),
            "delivery": .string(mode.rawValue),
            "text": .string(text),
            "target": target.document,
            "expected": witness.document
        ])
        guard body.count <= ConversationDeliveryWire.maxRequestBytes else {
            throw ConversationDeliveryRequestError.requestTooLarge(bytes: body.count)
        }
        self.requestID = requestID
        self.witness = witness
        self.target = target
        self.mode = mode
        self.text = text
        self.body = body
    }
}

// MARK: - ConversationDeliveryControlOperation

/// A control operation on one exact existing message.
public enum ConversationDeliveryControlOperation: String, Equatable, Sendable {
    case cancel
    case promoteNow = "promote_now"
}

// MARK: - ConversationDeliveryControlRequest

/// One immutable cancel or promote intent and its rendered request bytes.
///
/// `requestID` is a new operation id; `messageRequestID` names the existing message. The same
/// retry and rehydration rules as ``ConversationDeliverySendRequest`` apply.
public struct ConversationDeliveryControlRequest: Equatable, Sendable {
    public let requestID: UUID
    public let operation: ConversationDeliveryControlOperation
    public let messageRequestID: UUID
    public let witness: ConversationDeliveryWitness
    public let target: ConversationDeliveryTarget
    /// The exact bytes written to the request file.
    public let body: Data

    /// The operation id as sent on the wire: lowercase canonical UUID text.
    public var requestIDText: String { ConversationDeliveryWire.uuidText(requestID) }
    /// The message id as sent on the wire: lowercase canonical UUID text.
    public var messageRequestIDText: String { ConversationDeliveryWire.uuidText(messageRequestID) }

    /// Throws `ConversationDeliveryRequestError` for input the engine would refuse locally.
    public init(requestID: UUID, operation: ConversationDeliveryControlOperation, messageRequestID: UUID,
                witness: ConversationDeliveryWitness, target: ConversationDeliveryTarget) throws {
        try target.validate()
        let body = try ConversationDeliveryWire.render([
            "contract": .string(ConversationDeliveryWire.contract),
            "request_id": .string(ConversationDeliveryWire.uuidText(requestID)),
            "operation": .string(operation.rawValue),
            "target": target.document,
            "expected": witness.document,
            "message_request_id": .string(ConversationDeliveryWire.uuidText(messageRequestID))
        ])
        guard body.count <= ConversationDeliveryWire.maxRequestBytes else {
            throw ConversationDeliveryRequestError.requestTooLarge(bytes: body.count)
        }
        self.requestID = requestID
        self.operation = operation
        self.messageRequestID = messageRequestID
        self.witness = witness
        self.target = target
        self.body = body
    }
}
