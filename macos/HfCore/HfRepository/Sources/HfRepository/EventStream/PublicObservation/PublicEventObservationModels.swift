import Foundation
import MonitorCore

// MARK: - PublicEventObservationSnapshot

/// Internal, lifetime-scoped occurrence; never a legacy sequence anchor.
struct PublicEventOccurrence: Equatable, Sendable {
    /// Consumer-window identity, independent of producer sequence numbers.
    let epoch: UUID
    let admission: Int
    let record: TaskEventRecord
}

enum PublicEventSummaryPhase: Equatable, Sendable {
    case waiting, seeking, replaying, caughtUp, limited, unavailable
}

enum PublicEventObservationIssue: Hashable, Sendable {
    case capacity, nonprogress, historicalLimit, unavailable, resetExhausted
}

enum PublicEventPromptState: Equatable, Sendable {
    case notRequested
    case received(TaskPromptResult)
}

struct PublicEventObservationSnapshot: Equatable, Sendable {
    let sessionID: UUID
    /// Source/operation fence; changes on actual source adoption or runtime invalidation.
    var epoch = UUID()
    /// Fresh occurrence identity scope for every explicitly replaced activity window.
    var windowID = UUID()
    /// Retained activity belongs to the previous source until explicit adoption.
    var sourceChangePending = false
    /// Explicit older-page request pending; completion is published with its admitted rows.
    var historyLoading = false
    /// At least one observation lane awaits an explicit read retry.
    var pausedReads = false
    var revision = 0
    var activity: [PublicEventOccurrence] = []
    var rawBytes = 0
    var coverage = PublicEventCoverage()
    var olderCursor: String?
    var liveCursor: String?
    /// Summary frontier is independent of the activity delivery cursor. Never compare them as epoch proof.
    var summaryDeliveryCursor: String?
    var summaryPhase: PublicEventSummaryPhase = .waiting
    var summary = PublicEventSummaryReducer().snapshot(caughtUp: false)
    var issues: Set<PublicEventObservationIssue> = []
    var lifecycle: TaskEventLog?
    var forwardDrained = false
    var hasPendingLive = false
    var historicalOperations = 0
    var error: ToolError?
    var prompt: PublicEventPromptState = .notRequested
    var stopped = false
}

// MARK: - PublicEventCoverage

struct PublicEventCoverage: Equatable, Sendable {
    var malformed = 0
    var oversized = 0
    var gaps = 0
    var truncatedRecords = 0
    var unknownKinds = 0
    var nonIncreasingSequences = 0
}
