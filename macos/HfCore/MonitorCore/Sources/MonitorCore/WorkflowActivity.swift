import Foundation

// MARK: - WorkflowActivityReadIntent

/// Settled-only reads require positive complete public activation and attempt evidence at the caller.
public enum WorkflowActivityReadIntent: Equatable, Sendable {
    case settledOnly
    case allowUnsettled
}

// MARK: - WorkflowActivityPage

/// A bounded lossless activity answer. Missing legacy settlement metadata is not settlement proof.
public struct WorkflowActivityPage: Equatable, Sendable {
    public let events: [TaskEvent]
    public let hasMore: Bool
    public let settled: Bool?
    public let activityState: String?

    public init?(raw: [String: JSONValue], runID: String, executionID: String) {
        guard raw["workflow_run_id"]?.stringValue == runID, raw["execution_id"]?.stringValue == executionID,
              let records = raw["events"]?.arrayValue, records.count <= 200,
              let hasMore = raw["has_more"]?.boolValue else { return nil }
        if let value = raw["settled"], value.boolValue == nil { return nil }
        if let value = raw["activity_state"],
           !["available", "not_started", "unavailable"].contains(value.stringValue ?? "") { return nil }
        var events: [TaskEvent] = []
        for record in records {
            guard let object = record.objectValue,
                  WireEnvelope.validate(object, contract: .events) == nil,
                  let sequence = object["seq"]?.intValue, sequence >= 0,
                  let event = TaskEvent(line: record.rendered()) else { return nil }
            events.append(event)
        }
        self.events = events
        self.hasMore = hasMore
        settled = raw["settled"]?.boolValue
        activityState = raw["activity_state"]?.stringValue
    }
}
