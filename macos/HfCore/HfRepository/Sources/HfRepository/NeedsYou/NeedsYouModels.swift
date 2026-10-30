import Foundation
import MonitorCore

// MARK: - NeedsYouItem

/// One request the Monitor can answer now. Every rendered field takes part in equality except the
/// wait duration, which is derived from `waitingSince` and the clock.
public struct NeedsYouItem: Equatable, Sendable, Identifiable {
    /// What kind of answer the request takes.
    public enum Kind: String, Equatable, Sendable {
        case question, recovery, approval
    }

    /// The engine's ownership record for the interaction.
    public struct Ownership: Equatable, Sendable {
        /// `monitor`, `caller`, or an unrecognized wire value.
        public var owner: String
        /// The original caller has ended.
        public var callerEnded: Bool
        /// The engine's own explanation, empty when it gave none.
        public var engineNote: String
        /// The handover record, present only after the Monitor took over.
        public var handover: Handover?

        /// Creates an ownership record.
        public init(owner: String, callerEnded: Bool, engineNote: String, handover: Handover?) {
            self.owner = owner
            self.callerEnded = callerEnded
            self.engineNote = engineNote
            self.handover = handover
        }
    }

    /// When and why the Monitor took over from a caller.
    public struct Handover: Equatable, Sendable {
        public var timestamp: Date?
        public var reason: String
        public var previousOwner: String

        /// Creates a handover record.
        public init(timestamp: Date?, reason: String, previousOwner: String) {
            self.timestamp = timestamp
            self.reason = reason
            self.previousOwner = previousOwner
        }
    }

    public var id: String
    public var kind: Kind
    /// The workflow root the answer is sent to; empty for task approvals.
    public var rootRunID: String
    /// The run that raised the request (the root or a descendant).
    public var sourceRunID: String
    /// The workflow or task title.
    public var runTitle: String
    /// Run names from the root down to the node, as shown in the provenance block.
    public var pathTitles: [String]
    /// The full question, recovery reason, or the approval's action line.
    public var text: String
    /// Question prose items; display only, never answer tokens.
    public var questionItems: [String]
    /// The exact answers a usage-limit decision accepts; nil for a free-text request.
    public var offeredAnswers: [String]?
    /// Engine guidance for a usage-limit decision.
    public var resumeHint: String?
    public var ownership: Ownership
    /// "Mac app" or "Original caller": the engine reports no caller identity.
    public var startedBy: String
    public var waitingSince: Date?
    /// Whether the answer may grant additional attempts (recovery only).
    public var canAddAttempts: Bool
    /// The decision a question answers; nil otherwise.
    public var decisionID: String?
    /// The complete approval, for approval items.
    public var approval: CallerApprovalRequest?
    /// The task an approval belongs to.
    public var taskID: String?

    /// Creates an item.
    public init(
        id: String, kind: Kind, rootRunID: String = "", sourceRunID: String = "", runTitle: String, pathTitles: [String] = [],
        text: String, questionItems: [String] = [], offeredAnswers: [String]? = nil, resumeHint: String? = nil,
        ownership: Ownership, startedBy: String, waitingSince: Date? = nil, canAddAttempts: Bool = false,
        decisionID: String? = nil, approval: CallerApprovalRequest? = nil, taskID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.rootRunID = rootRunID
        self.sourceRunID = sourceRunID
        self.runTitle = runTitle
        self.pathTitles = pathTitles
        self.text = text
        self.questionItems = questionItems
        self.offeredAnswers = offeredAnswers
        self.resumeHint = resumeHint
        self.ownership = ownership
        self.startedBy = startedBy
        self.waitingSince = waitingSince
        self.canAddAttempts = canAddAttempts
        self.decisionID = decisionID
        self.approval = approval
        self.taskID = taskID
    }

    /// The first line of the request, for notifications and compact rows.
    public var firstLine: String {
        text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
    }

    static func ordered(_ lhs: NeedsYouItem, _ rhs: NeedsYouItem) -> Bool {
        switch (lhs.waitingSince, rhs.waitingSince) {
        case let (first?, second?) where first != second: first < second
        case (nil, _?): false
        case (_?, nil): true
        default: lhs.id < rhs.id
        }
    }
}

// MARK: - NeedsYouSnapshot

/// Everything the sidebar, list and menu bar render. Equality covers every field.
public struct NeedsYouSnapshot: Equatable, Sendable {
    /// Whether one full inventory cycle has completed.
    public enum Phase: Equatable, Sendable {
        case loading, ready
    }

    public var phase: Phase
    /// Answerable requests, oldest first.
    public var items: [NeedsYouItem]
    /// Sources that failed to read or were not qualified.
    public var unreadableSourceCount: Int
    /// Sources not visited this pass because of the per-pass budget; they rotate in later.
    public var deferredSourceCount: Int
    /// A qualified status of a ready engine lacked `interaction_state`.
    public var workflowInputsUnsupported: Bool

    /// Creates a snapshot.
    public init(
        phase: Phase = .loading, items: [NeedsYouItem] = [], unreadableSourceCount: Int = 0,
        deferredSourceCount: Int = 0, workflowInputsUnsupported: Bool = false
    ) {
        self.phase = phase
        self.items = items
        self.unreadableSourceCount = unreadableSourceCount
        self.deferredSourceCount = deferredSourceCount
        self.workflowInputsUnsupported = workflowInputsUnsupported
    }

    /// The count is a lower bound when any source was unread or deferred.
    public var isLowerBound: Bool { unreadableSourceCount + deferredSourceCount > 0 }
}

// MARK: - NeedsYouEvent

/// Disposable change events for notifications. They are deliberately not deduplicated.
public enum NeedsYouEvent: Equatable, Sendable {
    /// A request appeared. `sourceBaseline` is true for requests present in a source's first ready observation since launch.
    case appeared(NeedsYouItem, sourceBaseline: Bool)
    /// A ready observation of the source no longer reports the request, or it was answered here.
    case resolved(String)
}

// MARK: - NeedsYouAnswerOutcome

/// The result of sending an answer.
public enum NeedsYouAnswerOutcome: Equatable, Sendable {
    case accepted
    /// The original caller is alive again and owns the interaction.
    case callerReturned(String)
    /// The checkpoint moved on or the request is no longer available.
    case stale(String)
    /// An approval's action, revision or owner differs from what was shown; carries the refreshed request.
    case changed(NeedsYouItem?)
    case failed(String)

    static let changedMessage = "This request changed. Review it again."

    /// Classifies an engine refusal. Workflow refusals carry text only, so the text is matched here and nowhere else.
    static func classify(_ error: ToolError) -> Self {
        if let reason = error.callerApprovalResponseReason {
            switch reason {
            case .notCurrent, .alreadyAnswered, .settled, .expired, .ownershipLost:
                return .stale(error.message)
            default:
                return .failed(error.message)
            }
        }
        guard let code = error.refusalCode, code == "workflow_error" else { return .failed(error.message) }
        let message = rawMessage(error)
        if message.hasSuffix("; caller is alive") {
            return .callerReturned("The caller is answering this again.")
        }
        let stale = ["moved on", "is not currently available", "requires the current input decision_id",
                     "Workflow is terminal or cancelling", "caller is unknown", "belongs to its original caller"]
        if stale.contains(where: message.contains) { return .stale(message) }
        return .failed(message)
    }

    private static func rawMessage(_ error: ToolError) -> String {
        switch error {
        case .refused(_, let message), .structuredRefusal(_, let message, _): message
        default: error.message
        }
    }
}
