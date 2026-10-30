import Foundation

// MARK: - WorkflowInteractionState

/// The engine's `interaction_state` projection on a workflow status read: who may answer the
/// pending interaction now. Unrecognized wire values never grant Monitor authority.
public struct WorkflowInteractionState: Equatable, Sendable {
    /// The current interaction owner.
    public enum Owner: Equatable, Sendable {
        case caller, monitor
        case unrecognized(String)
    }

    /// What the engine knows about the original caller process.
    public enum CallerState: Equatable, Sendable {
        case alive, dead, unknown
        case unrecognized(String)
    }

    /// The record kept when the Monitor took over from a caller that had ended.
    public struct Handover: Equatable, Sendable {
        public let timestamp: Double?
        public let reason: String
        public let previousOwner: String
        public let responder: String
        public let action: String

        public init(timestamp: Double?, reason: String, previousOwner: String, responder: String, action: String) {
            self.timestamp = timestamp
            self.reason = reason
            self.previousOwner = previousOwner
            self.responder = responder
            self.action = action
        }
    }

    public let owner: Owner
    public let callerState: CallerState
    public let monitorAvailable: Bool
    public let reason: String
    public let handover: Handover?

    public init(owner: Owner, callerState: CallerState, monitorAvailable: Bool, reason: String, handover: Handover?) {
        self.owner = owner
        self.callerState = callerState
        self.monitorAvailable = monitorAvailable
        self.reason = reason
        self.handover = handover
    }

    /// Decodes the projection; nil when absent or not an object, which callers treat as unqualified.
    public init?(_ value: JSONValue?) {
        guard let object = value?.objectValue else { return nil }
        switch object["owner"]?.stringValue {
        case "caller": owner = .caller
        case "monitor": owner = .monitor
        case let other: owner = .unrecognized(other ?? "")
        }
        switch object["caller_state"]?.stringValue {
        case "alive": callerState = .alive
        case "dead": callerState = .dead
        case "unknown": callerState = .unknown
        case let other: callerState = .unrecognized(other ?? "")
        }
        monitorAvailable = object["monitor_available"]?.boolValue == true
        reason = object["reason"]?.stringValue ?? ""
        if let record = object["handover"]?.objectValue {
            handover = Handover(
                timestamp: record["timestamp"]?.doubleValue,
                reason: record["reason"]?.stringValue ?? "",
                previousOwner: record["previous_owner"]?.stringValue ?? "",
                responder: record["responder"]?.stringValue ?? "",
                action: record["action"]?.stringValue ?? ""
            )
        } else {
            handover = nil
        }
    }

    /// True only for recognized values the engine itself marks as available to the Monitor: the
    /// Monitor owns the interaction, or the original caller is proven dead.
    public var isAnswerableFromMonitor: Bool {
        guard monitorAvailable else { return false }
        if owner == .monitor { return true }
        return owner == .caller && callerState == .dead
    }
}

// MARK: - WorkflowPendingInput

/// One question entry of a root's `pending_inputs`, which covers the whole workflow tree.
public struct WorkflowPendingInput: Equatable, Sendable {
    public let workflowRunID: String
    public let workflowName: String
    public let nodeID: String
    public let nodeTitle: String
    public let path: [String]
    public let decisionID: String
    public let question: String
    public let questionItems: [String]
    public let waitingSince: Double?
    public let optionalReviewSkipAvailable: Bool
    public let kind: String?
    public let backend: String?
    public let model: String?
    public let resumeHint: String?

    /// Usage-limit entries are recovery decisions for a backend or model.
    public var isUsageLimit: Bool { kind == "usage_limit" }

    /// Decodes an entry; nil unless it names its run and decision.
    public init?(_ value: JSONValue) {
        guard let object = value.objectValue,
              let run = object["workflow_run_id"]?.stringValue, !run.isEmpty,
              let decision = object["decision_id"]?.stringValue, !decision.isEmpty else { return nil }
        workflowRunID = run
        workflowName = object["workflow_name"]?.stringValue ?? ""
        nodeID = object["node_id"]?.stringValue ?? ""
        nodeTitle = object["node_title"]?.stringValue ?? ""
        path = object["path"]?.arrayValue?.compactMap(\.stringValue) ?? []
        decisionID = decision
        question = object["question"]?.stringValue ?? ""
        questionItems = WorkflowMonitorStatus.items(object["question_items"])
        waitingSince = object["waiting_since"]?.doubleValue
        optionalReviewSkipAvailable = object["optional_review_skip_available"]?.boolValue == true
        kind = object["kind"]?.stringValue
        backend = object["backend"]?.stringValue
        model = object["model"]?.stringValue
        resumeHint = object["resume_hint"]?.stringValue
    }
}

// MARK: - WorkflowPendingAttention

/// One row of a root's `pending_attention`. It carries no decision id, so the engine cannot target it.
public struct WorkflowPendingAttention: Equatable, Sendable {
    public let workflowRunID: String
    public let workflowName: String
    public let nodeID: String
    public let nodeTitle: String
    public let path: [String]
    public let status: String
    public let reason: String
    public let waitingSince: Double?

    public init?(_ value: JSONValue) {
        guard let object = value.objectValue, let run = object["workflow_run_id"]?.stringValue, !run.isEmpty else { return nil }
        workflowRunID = run
        workflowName = object["workflow_name"]?.stringValue ?? ""
        nodeID = object["node_id"]?.stringValue ?? ""
        nodeTitle = object["node_title"]?.stringValue ?? ""
        path = object["path"]?.arrayValue?.compactMap(\.stringValue) ?? []
        status = object["status"]?.stringValue ?? ""
        reason = object["reason"]?.stringValue ?? ""
        waitingSince = object["waiting_since"]?.doubleValue
    }
}

// MARK: - WorkflowUsageLimitRecovery

/// A source run's structured usage-limit recovery: the exact answers the engine offers.
public struct WorkflowUsageLimitRecovery: Equatable, Sendable {
    public let decisionID: String
    public let choices: [String]

    public init?(_ value: JSONValue?) {
        guard let object = value?.objectValue, let decision = object["decision_id"]?.stringValue, !decision.isEmpty else { return nil }
        decisionID = decision
        choices = (object["choices"]?.arrayValue ?? []).compactMap { $0.objectValue?["answer"]?.stringValue }.filter { !$0.isEmpty }
    }
}

// MARK: - WorkflowMonitorControls

/// The advisory `monitor_controls` projection; every mutation is rechecked by the engine.
public struct WorkflowMonitorControl: Equatable, Sendable {
    public let allowed: Bool
    public let reason: String
}

// MARK: - WorkflowMonitorStatus

/// A typed view of `workflow-status <id> --monitor-view`. Tree roots expose `pending_inputs` and
/// `pending_attention`; a plain root exposes only the single-checkpoint fields, so both are read.
public struct WorkflowMonitorStatus: Equatable, Sendable {
    public let raw: [String: JSONValue]

    public init(_ raw: [String: JSONValue]) { self.raw = raw }

    private func text(_ key: String) -> String? { raw[key]?.stringValue }

    public var runID: String { text("workflow_run_id") ?? "" }
    public var name: String { text("name") ?? "" }
    public var kind: String { text("kind") ?? "" }
    public var status: String { text("status") ?? "" }
    public var parentRunID: String? { text("parent_workflow_run_id") }
    public var settling: Bool { raw["settling"]?.boolValue == true || raw["tree_settling"]?.boolValue == true }
    public var isTerminalOrCancelling: Bool { ["completed", "failed", "cancelled", "cancelling"].contains(status) }

    /// Present on engines that report caller loss; nil during bootstrap, a blocked catalog, or on an engine without it.
    public var interactionState: WorkflowInteractionState? { WorkflowInteractionState(raw["interaction_state"]) }

    /// False while the catalog is preparing or blocked, when projections may be absent or incomplete.
    public var isQualified: Bool { CatalogState(raw: raw).isReady }

    /// Whether the tree projection is present. A plain root has neither list.
    public var hasPendingInputsKey: Bool { raw["pending_inputs"]?.arrayValue != nil }
    public var pendingInputs: [WorkflowPendingInput] { (raw["pending_inputs"]?.arrayValue ?? []).compactMap(WorkflowPendingInput.init) }
    public var pendingAttention: [WorkflowPendingAttention] {
        (raw["pending_attention"]?.arrayValue ?? []).compactMap(WorkflowPendingAttention.init)
    }

    /// The root's selected checkpoint question, when it is waiting for input.
    public var inputQuestion: String? { text("input_question") }
    public var inputDecisionID: String? { text("input_decision_id").flatMap { $0.isEmpty ? nil : $0 } }
    public var inputQuestionItems: [String] { Self.items(raw["input_question_items"]) }
    public var inputSourceRunID: String? { raw["input_source"]?.objectValue?["workflow_run_id"]?.stringValue }
    public var inputSourceName: String? { raw["input_source"]?.objectValue?["workflow_name"]?.stringValue }
    public var inputSourcePath: [String] { raw["input_source"]?.objectValue?["path"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    public var attentionReason: String? { text("attention_reason") }
    public var optionalReviewSkipAvailable: Bool { raw["optional_review_skip_available"]?.boolValue == true }
    public var usageLimitRecovery: WorkflowUsageLimitRecovery? { WorkflowUsageLimitRecovery(raw["usage_limit_recovery"]) }

    public var resumeControl: WorkflowMonitorControl? { control("resume") }
    public var additionalAttemptsControl: WorkflowMonitorControl? { control("additional_attempts") }

    private func control(_ action: String) -> WorkflowMonitorControl? {
        guard let entry = raw["monitor_controls"]?.objectValue?[action]?.objectValue, let allowed = entry["allowed"]?.boolValue else { return nil }
        return WorkflowMonitorControl(allowed: allowed, reason: entry["reason"]?.stringValue ?? "")
    }

    static func items(_ value: JSONValue?) -> [String] {
        (value?.arrayValue ?? []).compactMap { item in
            if let text = item.stringValue { return text }
            let object = item.objectValue
            return object?["text"]?.stringValue ?? object?["question"]?.stringValue
        }
    }
}
