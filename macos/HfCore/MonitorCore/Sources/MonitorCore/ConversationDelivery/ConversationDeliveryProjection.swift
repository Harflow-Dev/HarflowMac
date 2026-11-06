import Foundation

// MARK: - Decoding helpers

extension Dictionary where Key == String, Value == JSONValue {
    /// A string field, or nil when missing or of another type.
    func deliveryString(_ key: String) -> String? { self[key]?.stringValue }

    /// An integer-token field at or above `minimum`, or nil.
    func deliveryInt(_ key: String, minimum: Int = 0) -> Int? {
        guard let value = self[key]?.wireIntegerValue, value >= minimum else { return nil }
        return value
    }

    /// Present and null, or present and a string; nil when missing or of another type.
    func deliveryNullableString(_ key: String) -> String?? {
        guard let value = self[key] else { return nil }
        if value == .null { return .some(nil) }
        return value.stringValue.map { .some($0) }
    }
}

// MARK: - ConversationDeliveryMessage

/// One retained message of a conversation ledger projection.
public struct ConversationDeliveryMessage: Equatable, Sendable {
    /// Open wire value; an unrecognized status is never treated as terminal, queued or `unknown`.
    public struct Status: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let queued = Status(rawValue: "queued")
        public static let claimed = Status(rawValue: "claimed")
        public static let consumed = Status(rawValue: "consumed")
        /// The engine could not establish the outcome. Distinct from any other unknown state.
        public static let unknown = Status(rawValue: "unknown")
        public static let cancelled = Status(rawValue: "cancelled")
    }

    /// Open wire value of the requested delivery priority.
    public struct Delivery: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let queue = Delivery(rawValue: "queue")
        public static let now = Delivery(rawValue: "now")
    }

    /// Open wire value of how a claim was issued.
    public struct Origin: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let queueDrain = Origin(rawValue: "queue_drain")
        public static let nowDelivery = Origin(rawValue: "now_delivery")
    }

    /// Where a claimed or consumed message was delivered.
    public struct Destination: Equatable, Sendable {
        public let taskID: String
        public let turnID: String
        public let generation: Int
        public let origin: Origin
        public let raw: [String: JSONValue]
    }

    /// Engine evidence that the destination consumed the input.
    public struct Receipt: Equatable, Sendable {
        public let kind: String
        public let taskID: String
        public let turnID: String
        public let generation: Int
        public let raw: [String: JSONValue]
    }

    public let requestID: String
    public let text: String
    public let delivery: Delivery
    public let sequence: Int
    public let status: Status
    public let targetTaskID: String
    /// Always emitted by the engine; null when the message was never retargeted.
    public let originalTargetTaskID: String?
    /// The ledger position the message was admitted at. The engine always emits all three.
    public let sourceGeneration: Int
    public let sourceTurnID: String
    public let sourceEpoch: Int
    public let destination: Destination?
    public let receipt: Receipt?
    /// Present when a promotion was accepted. Delivery stays `queue`.
    public let promotionRequestID: String?
    public let cancellationRequestID: String?
    /// The original message object, including additive fields.
    public let raw: [String: JSONValue]

    /// Whether a promotion was accepted for this message.
    public var isPromoted: Bool { promotionRequestID != nil }

    /// Effective Now priority: requested Now, or promoted from the queue.
    public var hasNowPriority: Bool { delivery == .now || isPromoted }

    init?(raw: [String: JSONValue]) {
        guard let requestID = raw.deliveryString("request_id"), ConversationDeliveryWire.isCanonicalUUID(requestID),
              let text = raw.deliveryString("text"), let delivery = raw.deliveryString("delivery"),
              let sequence = raw.deliveryInt("sequence"), let status = raw.deliveryString("status"),
              let target = raw.deliveryString("target_task_id"),
              let originalTarget = raw.deliveryNullableString("original_target_task_id"),
              let sourceGeneration = raw.deliveryInt("source_generation"),
              let sourceTurnID = raw.deliveryString("source_turn_id"),
              let sourceEpoch = raw.deliveryInt("source_epoch") else { return nil }
        var destination: Destination?
        if let value = raw["destination"] {
            guard let object = value.objectValue, let task = object.deliveryString("task_id"),
                  let turn = object.deliveryString("turn_id"), let generation = object.deliveryInt("generation"),
                  let origin = object.deliveryString("origin") else { return nil }
            destination = Destination(taskID: task, turnID: turn, generation: generation,
                                      origin: Origin(rawValue: origin), raw: object)
        }
        var receipt: Receipt?
        if let value = raw["receipt"] {
            guard let object = value.objectValue, let kind = object.deliveryString("kind"),
                  let task = object.deliveryString("task_id"), let turn = object.deliveryString("turn_id"),
                  let generation = object.deliveryInt("generation") else { return nil }
            receipt = Receipt(kind: kind, taskID: task, turnID: turn, generation: generation, raw: object)
        }
        for key in ["promotion_request_id", "cancellation_request_id"] {
            if let value = raw[key], value.stringValue == nil { return nil }
        }
        self.requestID = requestID
        self.text = text
        self.delivery = Delivery(rawValue: delivery)
        self.sequence = sequence
        self.status = Status(rawValue: status)
        targetTaskID = target
        originalTargetTaskID = originalTarget
        self.sourceGeneration = sourceGeneration
        self.sourceTurnID = sourceTurnID
        self.sourceEpoch = sourceEpoch
        self.destination = destination
        self.receipt = receipt
        promotionRequestID = raw.deliveryString("promotion_request_id")
        cancellationRequestID = raw.deliveryString("cancellation_request_id")
        self.raw = raw
    }
}

// MARK: - ConversationDeliveryProgress

/// Native progress of the conversation, when the engine reports it.
public struct ConversationDeliveryProgress: Equatable, Sendable {
    /// Open wire value; an unrecognized phase is never treated as terminal or as `unknown`.
    public struct Phase: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let starting = Phase(rawValue: "starting")
        public static let issuing = Phase(rawValue: "issuing")
        public static let responding = Phase(rawValue: "responding")
        public static let interrupting = Phase(rawValue: "interrupting")
        public static let waitingTools = Phase(rawValue: "waiting_tools")
        public static let boundary = Phase(rawValue: "boundary")
        /// The engine could not establish progress. Distinct from an unrecognized phase.
        public static let unknown = Phase(rawValue: "unknown")
        public static let closed = Phase(rawValue: "closed")
    }

    public let generation: Int
    public let logicalTurn: String
    public let nativeTerminal: String?
    public let pendingApprovals: Int
    public let pendingTools: Int
    public let phase: Phase
    public let unsettledEffects: Int
    public let raw: [String: JSONValue]

    init?(raw: [String: JSONValue]) {
        guard let generation = raw.deliveryInt("generation"), let turn = raw.deliveryString("logical_turn"),
              let terminal = raw.deliveryNullableString("native_terminal"),
              let approvals = raw.deliveryInt("pending_approvals"), let tools = raw.deliveryInt("pending_tools"),
              let phase = raw.deliveryString("phase"), let effects = raw.deliveryInt("unsettled_effects")
        else { return nil }
        self.generation = generation
        logicalTurn = turn
        nativeTerminal = terminal
        pendingApprovals = approvals
        pendingTools = tools
        self.phase = Phase(rawValue: phase)
        unsettledEffects = effects
        self.raw = raw
    }
}

// MARK: - ConversationDeliveryAccounting

/// Token and cost accounting facts of the conversation. Absent cost is never zero.
public struct ConversationDeliveryAccounting: Equatable, Sendable {
    public let settledResponses: Int
    public let accountedGeneration: Int
    public let usageComplete: Bool
    public let observedCostUSD: Double?
    public let lastCostUSD: Double?
    /// Open wire value; the engine emits `response_local`, `native_cumulative` or `unavailable`.
    public let costBasis: String
    public let lastCostBasis: String
    public let raw: [String: JSONValue]

    init?(raw: [String: JSONValue]) {
        guard let settled = raw.deliveryInt("settled_responses"),
              let accounted = raw.deliveryInt("accounted_generation", minimum: -1),
              let complete = raw["usage_complete"]?.boolValue,
              let costBasis = raw.deliveryString("cost_basis"),
              let lastCostBasis = raw.deliveryString("last_cost_basis") else { return nil }
        // Both cost keys are always emitted; null means unavailable, and a missing key is malformed.
        for key in ["observed_cost_usd", "last_cost_usd"] {
            guard let value = raw[key], value == .null || value.doubleValue != nil else { return nil }
        }
        settledResponses = settled
        accountedGeneration = accounted
        usageComplete = complete
        observedCostUSD = raw["observed_cost_usd"]?.doubleValue
        lastCostUSD = raw["last_cost_usd"]?.doubleValue
        self.costBasis = costBasis
        self.lastCostBasis = lastCostBasis
        self.raw = raw
    }
}

// MARK: - ConversationDeliveryRuntimeFault

/// A native runtime fault reported by the engine.
public struct ConversationDeliveryRuntimeFault: Equatable, Sendable {
    public let code: String
    public let generation: Int
    public let turnID: String
    public let raw: [String: JSONValue]
}

// MARK: - ConversationDeliveryReconciliation

/// What a projection says about one request id.
public enum ConversationDeliveryReconciliation: Equatable, Sendable {
    /// Which message field carried the id.
    public enum MatchedField: String, Equatable, Sendable {
        case requestID = "request_id"
        case promotionRequestID = "promotion_request_id"
        case cancellationRequestID = "cancellation_request_id"
    }

    /// The projection retains a message that carries the id.
    case retained(ConversationDeliveryMessage, matchedField: MatchedField)
    /// The projection retains no such id. This does not prove the request was never admitted,
    /// because compaction retires old entries.
    case absentFromRetainedWindow
}

// MARK: - ConversationDeliveryProjection

/// The conversation ledger as the engine projects it: witness, progress, accounting and the
/// retained message window.
///
/// Reconciling against a projection reads the projection only. It never refreshes a request:
/// a later retry resends the original request value, not a witness taken from a newer
/// projection. A prepare call used for reconciliation can enroll the task and can itself
/// refuse; a failed prepare leaves the state uncertain. When a prepared target is used to
/// build a send, only an exact complete task id may become a `.task` target, because the
/// engine refuses a prefix at send.
public struct ConversationDeliveryProjection: Equatable, Sendable {
    public let contract: String
    /// The witness a request built from this projection would carry.
    public let expected: ConversationDeliveryWitness
    public let closed: Bool
    public let cumulativeIssuances: Int
    public let accounting: ConversationDeliveryAccounting
    /// Nil when the engine reports no runtime fault.
    public let runtimeFault: ConversationDeliveryRuntimeFault?
    /// Absent when the engine omitted it; the engine emits it conditionally.
    public let progress: ConversationDeliveryProgress?
    /// Present for a workflow activation; absent for a standalone task.
    public let target: ConversationDeliveryTarget?
    public let messages: [ConversationDeliveryMessage]
    /// The original result object, including `resolved_from` and additive fields.
    public let raw: [String: JSONValue]

    /// Decodes a `conversation-prepare` result and fails closed on a missing or malformed
    /// required field, a foreign contract, or a target whose task id matches neither the
    /// requested id nor the `resolved_from` id. `head_task_id` is not compared to the request.
    public init?(raw: [String: JSONValue], requestedTaskID: String? = nil) {
        guard raw["contract"]?.stringValue == ConversationDeliveryWire.contract,
              let expectedObject = raw["expected"]?.objectValue,
              let conversation = expectedObject.deliveryString("conversation_id"),
              let head = expectedObject.deliveryString("head_task_id"),
              let generation = expectedObject.deliveryInt("generation"),
              let turn = expectedObject.deliveryString("turn_id"),
              let epoch = expectedObject.deliveryInt("ledger_epoch"),
              let witness = try? ConversationDeliveryWitness(conversationID: conversation, headTaskID: head,
                                                             generation: generation, turnID: turn, ledgerEpoch: epoch),
              let closed = raw["closed"]?.boolValue,
              let issuances = raw.deliveryInt("cumulative_issuances"),
              let accountingObject = raw["accounting"]?.objectValue,
              let accounting = ConversationDeliveryAccounting(raw: accountingObject),
              let messageValues = raw["messages"]?.arrayValue else { return nil }
        var fault: ConversationDeliveryRuntimeFault?
        switch raw["runtime_fault"] {
        case .some(.null): fault = nil
        case .some(.object(let object)):
            guard let code = object.deliveryString("code"), let faultGeneration = object.deliveryInt("generation"),
                  let faultTurn = object.deliveryString("turn_id") else { return nil }
            fault = ConversationDeliveryRuntimeFault(code: code, generation: faultGeneration,
                                                     turnID: faultTurn, raw: object)
        default: return nil
        }
        var progress: ConversationDeliveryProgress?
        if let value = raw["progress"] {
            guard let object = value.objectValue, let decoded = ConversationDeliveryProgress(raw: object) else { return nil }
            progress = decoded
        }
        var target: ConversationDeliveryTarget?
        if let value = raw["target"] {
            guard let object = value.objectValue, let decoded = Self.decodeTarget(object) else { return nil }
            let resolved = raw["resolved_from"]?.objectValue?.deliveryString("task_id")
            if let requestedTaskID, decoded.taskID != requestedTaskID, decoded.taskID != resolved { return nil }
            target = decoded
        }
        var messages: [ConversationDeliveryMessage] = []
        messages.reserveCapacity(messageValues.count)
        for value in messageValues {
            guard let object = value.objectValue, let message = ConversationDeliveryMessage(raw: object) else { return nil }
            messages.append(message)
        }
        contract = ConversationDeliveryWire.contract
        expected = witness
        self.closed = closed
        cumulativeIssuances = issuances
        self.accounting = accounting
        runtimeFault = fault
        self.progress = progress
        self.target = target
        self.messages = messages
        self.raw = raw
    }

    private static func decodeTarget(_ object: [String: JSONValue]) -> ConversationDeliveryTarget? {
        switch object.deliveryString("kind") {
        case "task":
            guard let task = object.deliveryString("task_id") else { return nil }
            return .task(taskID: task)
        case "workflow_activation":
            guard let run = object.deliveryString("workflow_run_id"), let activation = object.deliveryString("activation_id"),
                  let task = object.deliveryString("task_id") else { return nil }
            return .workflowActivation(workflowRunID: run, activationID: activation, taskID: task)
        default:
            return nil
        }
    }

    /// Searches `request_id`, `promotion_request_id` and `cancellation_request_id`, as the
    /// engine does. Absence from the retained window is not proof of non-admission.
    public func reconciliation(for requestID: String) -> ConversationDeliveryReconciliation {
        for message in messages {
            if message.requestID == requestID { return .retained(message, matchedField: .requestID) }
            if message.promotionRequestID == requestID { return .retained(message, matchedField: .promotionRequestID) }
            if message.cancellationRequestID == requestID { return .retained(message, matchedField: .cancellationRequestID) }
        }
        return .absentFromRetainedWindow
    }

    /// Convenience for a stored request id; the id is matched as lowercase canonical text.
    public func reconciliation(for requestID: UUID) -> ConversationDeliveryReconciliation {
        reconciliation(for: ConversationDeliveryWire.uuidText(requestID))
    }
}
