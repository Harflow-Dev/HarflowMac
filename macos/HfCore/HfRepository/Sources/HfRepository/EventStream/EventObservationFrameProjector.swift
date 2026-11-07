import Foundation
import MonitorCore

// MARK: - EventObservationFrameProjector

/// Projects only sound known payloads; raw normalized evidence always survives.
enum EventObservationFrameProjector {
    static func project(taskID: String, snapshot: PublicEventObservationSnapshot) -> EventObservationFrame {
        let scope = EventObservationScope(sessionID: snapshot.sessionID, sourceID: snapshot.epoch, windowID: snapshot.windowID)
        let records = snapshot.activity.map {
            ObservedEventRecord(id: EventOccurrenceID(scope: scope, admission: $0.admission), record: $0.record)
        }
        var reasons = coverageReasons(snapshot)
        var events: [TaskEvent] = []
        var builder = TimelineBuilder()
        var previous: Int?
        // Page boundaries are not retained by D2A. When page-level loss is known, do not
        // guess its position: disable all cross-record pairing for this retained window.
        let uncertainBoundaries = snapshot.coverage.malformed > 0 || snapshot.coverage.oversized > 0
            || snapshot.coverage.gaps > 0 || snapshot.coverage.nonIncreasingSequences > 0
        for (index, occurrence) in snapshot.activity.enumerated() {
            let record = occurrence.record
            if uncertainBoundaries || previous.map({ $0 == Int.max || record.seq != $0 + 1 }) == true {
                builder.breakContinuity()
                if let previous {
                    if record.seq <= previous { reasons.insert(.ambiguousOrder) }
                }
            }
            previous = record.seq
            guard record.truncated != true, record.oversized != true else {
                reasons.insert(.normalizationLoss)
                builder.breakContinuity()
                continue
            }
            guard knownKinds.contains(record.kind) else {
                reasons.insert(.unknownKind)
                builder.breakContinuity()
                continue
            }
            let rawLine = records[index].normalizedJSON
            guard validPayload(record), optionalString(record.raw["source_ts"]),
                  let decoded = TaskEvent(line: rawLine) else {
                reasons.insert(.unsupportedPayload)
                builder.breakContinuity()
                continue
            }
            let event = TaskEvent(seq: record.seq, displayID: occurrence.admission,
                                  observedAt: decoded.observedAt, sourceTimestamp: decoded.sourceTimestamp,
                                  kind: decoded.kind, rawLine: rawLine)
            events.append(event)
            builder.append([event])
        }
        let reconnecting = snapshot.error != nil || snapshot.pausedReads || snapshot.stopped
        let actions = availableActions(snapshot)
        let history = EventObservationHistory(
            isLoading: snapshot.historyLoading || (snapshot.lifecycle == nil && snapshot.error == nil && !snapshot.stopped),
            hasOlder: snapshot.olderCursor != nil,
            caughtUp: snapshot.forwardDrained && !snapshot.sourceChangePending && !reconnecting,
            forwardDrained: snapshot.forwardDrained, reasons: reasons,
            currentness: snapshot.sourceChangePending ? .sourceChangePending : reconnecting ? .reconnecting : .current,
            availableActions: actions, failure: snapshot.error
        )
        return EventObservationFrame(taskID: taskID, scope: scope, revision: snapshot.revision,
                                     records: records, events: events, items: builder.items,
                                     history: history, summary: summary(snapshot.summary),
                                     logState: logState(snapshot))
    }

    /// After a capacity or nonprogress rejection newer pages are dropped, so the last recorded state may be
    /// stale; it is withheld (nil) so consumers never claim settling or final from it.
    private static func logState(_ snapshot: PublicEventObservationSnapshot) -> EventLogState? {
        guard let log = snapshot.lifecycle,
              !snapshot.issues.contains(.capacity), !snapshot.issues.contains(.nonprogress) else { return nil }
        return switch log.state {
        case .open: .open
        case .settling: .settling
        case .final: .final
        case .incomplete: .incomplete
        case .unknown: .unknown
        case .unavailable: .unavailable
        }
    }

    private static func availableActions(_ snapshot: PublicEventObservationSnapshot) -> Set<EventObservationAction> {
        var actions: Set<EventObservationAction> = []
        if !snapshot.stopped {
            if snapshot.sourceChangePending {
                if !snapshot.issues.contains(.resetExhausted), snapshot.historicalOperations < 4096 {
                    actions.insert(.adoptCurrentSource)
                }
            } else {
                if snapshot.olderCursor != nil, !snapshot.historyLoading,
                   !snapshot.issues.contains(.capacity), !snapshot.issues.contains(.historicalLimit) {
                    actions.insert(.loadEarlier)
                }
                if snapshot.error != nil || snapshot.pausedReads || snapshot.issues.contains(.nonprogress) { actions.insert(.retryRead) }
                if snapshot.issues.contains(.capacity) { actions.insert(.rebaseWindow) }
            }
        }
        return actions
    }

    private static let knownKinds: Set<String> = [
        "task_started", "assistant_text", "assistant_delta", "tool_call", "tool_result",
        "user_message", "usage", "notice", "task_finished", "undelivered"
    ]

    private static func coverageReasons(_ snapshot: PublicEventObservationSnapshot) -> Set<EventObservationReason> {
        var reasons: Set<EventObservationReason> = []
        let coverage = snapshot.coverage
        if coverage.malformed > 0 || coverage.oversized > 0 { reasons.insert(.skippedRecords) }
        if coverage.gaps > 0 { reasons.insert(.gaps) }
        if coverage.truncatedRecords > 0 { reasons.insert(.normalizationLoss) }
        if coverage.unknownKinds > 0 { reasons.insert(.unknownKind) }
        if coverage.nonIncreasingSequences > 0 { reasons.insert(.ambiguousOrder) }
        for issue in snapshot.issues {
            switch issue {
            case .capacity: reasons.insert(.capacity)
            case .nonprogress: reasons.insert(.nonprogress)
            case .historicalLimit: reasons.insert(.historicalLimit)
            case .unavailable: reasons.insert(.unavailable)
            case .resetExhausted: reasons.insert(.resetExhausted)
            }
        }
        if let log = snapshot.lifecycle,
           !["live", "observed_terminal"].contains(log.captureState)
           || [.incomplete, .unknown, .unavailable].contains(log.state) { reasons.insert(.captureUnavailable) }
        return reasons
    }

    private static func summary(_ summary: PublicEventSummary) -> ObservedActivitySummary {
        let state: ObservedActivitySummary.State = switch summary.state {
        case .loading: .loading
        case .observed: .observed
        case .unavailable: .unavailable
        case .limited: .limited
        }
        let reasons = Set(summary.issues.map(summaryReason))
        return ObservedActivitySummary(state: state, counts: summary.counts, files: summary.files,
                                       totalFiles: summary.totalFiles, reasons: reasons)
    }

    private static func summaryReason(_ issue: PublicEventSummaryIssue) -> EventObservationReason {
        switch issue {
        case .normalizationLoss: .normalizationLoss
        case .skippedRecords: .skippedRecords
        case .gaps: .gaps
        case .captureUnavailable: .captureUnavailable
        case .unknownKind: .unknownKind
        case .unsupportedPayload: .unsupportedPayload
        case .ambiguousOrder: .ambiguousOrder
        case .ambiguousCall: .ambiguousCall
        case .capacity: .capacity
        case .historicalLimit: .historicalLimit
        case .nonprogress: .nonprogress
        case .requestUnavailable: .requestUnavailable
        }
    }

    private static func optionalString(_ value: JSONValue?) -> Bool {
        value == nil || value == .null || value?.stringValue != nil
    }
}

// MARK: - Strict known payload validation

private extension EventObservationFrameProjector {
    static func validPayload(_ record: TaskEventRecord) -> Bool {
        let raw = record.raw
        switch record.kind {
        case "task_started":
            return strings(raw, required: ["prompt"], optional: ["repo_path", "backend", "freedom", "model", "reasoning_effort", "spawned_by", "group"])
                && optionalBool(raw["live_input"])
        case "assistant_text", "assistant_delta":
            return strings(raw, required: ["text"], optional: ["message_id"]) && optionalInteger(raw["block_index"])
        case "user_message": return strings(raw, required: ["text"], optional: ["source", "message_id"])
        case "notice": return strings(raw, required: ["text"], optional: [])
        case "tool_call": return validCall(raw)
        case "tool_result":
            return strings(raw, required: ["call_id", "output_tail"], optional: [])
                && raw["call_id"]?.stringValue?.isEmpty == false && raw["ok"]?.boolValue != nil && optionalInteger(raw["exit_code"])
        case "task_finished":
            return strings(raw, required: ["status"], optional: ["summary"]) && raw["status"]?.stringValue?.isEmpty == false
                && optionalInteger(raw["exit_code"]) && optionalBool(raw["observed"])
        case "undelivered":
            return strings(raw, required: ["message_id", "text", "reason"], optional: [])
        case "usage": return validUsage(raw)
        default: return false
        }
    }

    static func validCall(_ raw: [String: JSONValue]) -> Bool {
        guard strings(raw, required: ["call_id", "tool", "category", "input_preview"], optional: ["path", "command"]),
              ["call_id", "tool", "category"].allSatisfy({ raw[$0]?.stringValue?.isEmpty == false }) else { return false }
        guard let edit = raw["edit"], edit != .null else { return true }
        guard let object = edit.objectValue else { return false }
        return strings(object, required: [], optional: ["old", "new"])
    }

    static func validUsage(_ raw: [String: JSONValue]) -> Bool {
        let cost = raw["total_cost_usd"]
        let turns = raw["num_turns"]
        let validCost = cost == nil || cost == .null || cost?.doubleValue.map { $0.isFinite && $0 >= 0 } == true
        return validCost && optionalInteger(turns) && (cost?.doubleValue != nil || turns?.wireIntegerValue != nil)
    }

    static func strings(_ raw: [String: JSONValue], required: [String], optional: [String]) -> Bool {
        required.allSatisfy { raw[$0]?.stringValue != nil }
            && optional.allSatisfy { raw[$0] == nil || raw[$0] == .null || raw[$0]?.stringValue != nil }
    }

    static func optionalBool(_ value: JSONValue?) -> Bool { value == nil || value == .null || value?.boolValue != nil }
    static func optionalInteger(_ value: JSONValue?) -> Bool { value == nil || value == .null || value?.wireIntegerValue != nil }
}
