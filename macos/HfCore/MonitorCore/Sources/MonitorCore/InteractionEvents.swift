import Foundation

// MARK: - InteractionNotificationEvent

/// One durable request, answer, or task completion from the selected engine.
public struct InteractionNotificationEvent: Sendable, Equatable {
    public let id: String
    public let state: String
    public let kind: String
    public let title: String
    public let body: String
    public let answeredBy: String?
    public let occurredAt: Double
    public let workflowRunID: String?
    public let taskID: String?
    public let monitorAvailable: Bool

    public init?(_ raw: [String: JSONValue]) {
        guard let id = raw["event_id"]?.stringValue, !id.isEmpty, id.count <= 1024,
              let state = raw["state"]?.stringValue, ["pending", "answered", "completed", "failed"].contains(state),
              let kind = raw["kind"]?.stringValue, ["question", "approval", "recovery", "task"].contains(kind),
              let timestamp = raw["occurred_at"]?.doubleValue, timestamp.isFinite, timestamp > 0,
              let title = raw["title"]?.stringValue else { return nil }
        let responder = raw["answered_by"]?.stringValue
        if state == "answered", !["caller", "monitor"].contains(responder ?? "") { return nil }
        self.id = id
        self.state = state
        self.kind = kind
        self.title = title
        self.body = raw[state == "answered" ? "answer" : "question"]?.stringValue ?? ""
        self.answeredBy = responder
        self.occurredAt = timestamp
        self.workflowRunID = raw["workflow_run_id"]?.stringValue
        self.taskID = raw["task_id"]?.stringValue
        self.monitorAvailable = raw["monitor_available"]?.boolValue ?? (kind == "task")
    }
}

// MARK: - InteractionEventPage

/// A bounded scan page. Complete cycles replay stable IDs for persistent consumer deduplication.
public struct InteractionEventPage: Sendable {
    public let events: [InteractionNotificationEvent]
    public let nextCursor: String?
    public let cycleComplete: Bool
    public let historyIncomplete: Bool

    init?(_ raw: [String: JSONValue]) {
        guard let rows = raw["events"]?.arrayValue, rows.count <= 100,
              let complete = raw["cycle_complete"]?.boolValue,
              let incomplete = raw["history_incomplete"]?.boolValue else { return nil }
        let events = rows.compactMap { $0.objectValue.flatMap(InteractionNotificationEvent.init) }
        guard events.count == rows.count else { return nil }
        self.events = events
        self.nextCursor = raw["next_cursor"]?.stringValue
        self.cycleComplete = complete
        self.historyIncomplete = incomplete
        if !complete, nextCursor == nil { return nil }
    }
}

public extension CtlClient {
    /// Reads retained interaction episodes without starting notification delivery or mutating engine state.
    func interactionEvents(cursor: String? = nil) async -> Result<InteractionEventPage, ToolError> {
        var options = ["--limit=50"]
        if let cursor { options.append("--cursor=\(cursor)") }
        return await result("interaction-events", options: options, requiringCapability: "interaction-events.v1").flatMap {
            guard let page = InteractionEventPage($0) else {
                return .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Malformed interaction event page"))
            }
            return .success(page)
        }
    }
}
