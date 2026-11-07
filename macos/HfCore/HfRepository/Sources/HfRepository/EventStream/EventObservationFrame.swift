import Foundation
import MonitorCore

// MARK: - EventObservationScope

/// Local observation identity; this is not a producer generation certificate.
public struct EventObservationScope: Hashable, Sendable {
    public let sessionID: UUID
    public let sourceID: UUID
    public let windowID: UUID

    /// Creates a scope for one retained consumer window.
    public init(sessionID: UUID, sourceID: UUID, windowID: UUID) {
        self.sessionID = sessionID
        self.sourceID = sourceID
        self.windowID = windowID
    }

    /// Stable identity prefix for presentation rows and reading anchors.
    public var identity: String { "\(sessionID.uuidString)/\(sourceID.uuidString)/\(windowID.uuidString)" }
}

// MARK: - EventOccurrenceID

/// File-order occurrence identity, independent of possibly repeated producer sequences.
public struct EventOccurrenceID: Hashable, Sendable {
    public let scope: EventObservationScope
    public let admission: Int

    /// Creates an identity from a scope and its admitted occurrence number.
    public init(scope: EventObservationScope, admission: Int) {
        self.scope = scope
        self.admission = admission
    }
}

// MARK: - ObservedEventRecord

/// Bounded public normalized evidence, including records with unsupported semantics.
public struct ObservedEventRecord: Equatable, Identifiable, Sendable {
    public let id: EventOccurrenceID
    public let record: TaskEventRecord
    /// Prepared with the frame off the main actor; rendering and copying use these same bytes.
    public let normalizedJSON: String

    /// Retains the public record without inventing omitted payload fields.
    public init(id: EventOccurrenceID, record: TaskEventRecord) {
        self.id = id
        self.record = record
        self.normalizedJSON = JSONValue.object(record.raw).rendered()
    }
}

// MARK: - EventObservationHistory

/// Independent qualifications on the observed history or aggregate projection.
public enum EventObservationReason: String, Hashable, Sendable {
    case normalizationLoss, skippedRecords, gaps, captureUnavailable, unknownKind
    case unsupportedPayload, ambiguousOrder, ambiguousCall, capacity
    case historicalLimit, nonprogress, requestUnavailable, unavailable, resetExhausted
}

/// Explicit observation actions; none restarts task execution.
public enum EventObservationAction: Hashable, Sendable {
    case loadEarlier, retryRead, rebaseWindow, adoptCurrentSource
}

/// Whether retained rows belong to the currently observed source.
public enum EventObservationCurrentness: Equatable, Sendable {
    case current, reconnecting, sourceChangePending
}

/// Orthogonal loading, coverage, freshness and recovery facts.
public struct EventObservationHistory: Equatable, Sendable {
    public let isLoading: Bool
    public let hasOlder: Bool
    public let caughtUp: Bool
    public let forwardDrained: Bool
    public let reasons: Set<EventObservationReason>
    public let currentness: EventObservationCurrentness
    public let availableActions: Set<EventObservationAction>
    /// Public refusal/read details, including actionable capability requirements.
    public let failure: ToolError?

    /// Creates independent history facts. Empty defaults do not claim caught-up history.
    public init(isLoading: Bool = false, hasOlder: Bool = false, caughtUp: Bool = false,
                forwardDrained: Bool = false, reasons: Set<EventObservationReason> = [],
                currentness: EventObservationCurrentness = .current,
                availableActions: Set<EventObservationAction> = [], failure: ToolError? = nil) {
        self.isLoading = isLoading
        self.hasOlder = hasOlder
        self.caughtUp = caughtUp
        self.forwardDrained = forwardDrained
        self.reasons = reasons
        self.currentness = currentness
        self.availableActions = availableActions
        self.failure = failure
    }
}

// MARK: - ObservedActivitySummary

/// Qualified aggregate state, independent of visible-window capacity.
public struct ObservedActivitySummary: Equatable, Sendable {
    /// Only observed state carries usable aggregate values.
    public enum State: Equatable, Sendable { case loading, observed, unavailable, limited }
    public let state: State
    public let counts: ActivityCounts?
    public let files: [EditedFile]
    public let totalFiles: Int?
    public let reasons: Set<EventObservationReason>

    /// Creates a summary; uncertain states discard partial aggregate values.
    public init(state: State = .loading, counts: ActivityCounts? = nil, files: [EditedFile] = [],
                totalFiles: Int? = nil, reasons: Set<EventObservationReason> = []) {
        self.state = state
        self.counts = state == .observed ? counts : nil
        self.files = state == .observed ? files : []
        self.totalFiles = state == .observed ? totalFiles : nil
        self.reasons = reasons
    }
}

// MARK: - EventLogState

/// The event log's lifecycle state (`log.state` on the wire).
///
/// Unknown wire states never reach the frame: MonitorCore rejects them, and they arrive as `nil`.
public enum EventLogState: Hashable, Sendable {
    case open, settling, final, incomplete, unknown, unavailable
}

// MARK: - EventObservationFrame

/// One atomic revision of bounded captured records, semantic rows and qualified facts.
public struct EventObservationFrame: Equatable, Sendable {
    public let taskID: String
    public let scope: EventObservationScope
    public let revision: Int
    public let records: [ObservedEventRecord]
    public let events: [TaskEvent]
    public let items: [TimelineItem]
    public let history: EventObservationHistory
    public let summary: ObservedActivitySummary
    /// The latest observed `log.state`; `nil` until a page reports it, after a window replacement, and while
    /// the observation has refused newer pages (capacity or nonprogress), when the last state may be stale.
    public let logState: EventLogState?

    /// Creates a frame, including empty/loading mock frames without fabricated zero totals.
    public init(taskID: String, scope: EventObservationScope, revision: Int = 0,
                records: [ObservedEventRecord] = [], events: [TaskEvent] = [], items: [TimelineItem] = [],
                history: EventObservationHistory = .init(isLoading: true),
                summary: ObservedActivitySummary = .init(), logState: EventLogState? = nil) {
        self.taskID = taskID
        self.scope = scope
        self.revision = revision
        self.records = records
        self.events = events
        self.items = items
        self.history = history
        self.summary = summary
        self.logState = logState
    }
}

// MARK: - TaskRequestReadState

/// Stored assignment provenance is read separately from captured display events.
public enum TaskRequestReadState: Equatable, Sendable {
    case notRequested
    case loading(maxBytes: Int)
    case received(TaskPromptResult, maxBytes: Int)
    case failed(ToolError, maxBytes: Int)
}

// MARK: - RecoveredTranscriptFrame

/// Display-only recovered evidence with separate provenance; never captured-count authority.
public struct RecoveredTranscriptFrame: Equatable, Sendable {
    public let generation: UUID?
    public let events: [TaskEvent]
    public let items: [TimelineItem]

    /// Creates an independently scoped recovered transcript, empty before a qualified read.
    public init(generation: UUID? = nil, events: [TaskEvent] = [], items: [TimelineItem] = []) {
        self.generation = generation
        self.events = events
        self.items = items
    }
}
