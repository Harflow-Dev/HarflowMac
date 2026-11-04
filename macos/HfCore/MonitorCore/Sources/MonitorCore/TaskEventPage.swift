import Foundation

// MARK: - TaskEventPagePosition

/// A page origin; cursors remain opaque and never combine with a from-position.
public enum TaskEventPagePosition: Equatable, Sendable {
    case newest, oldest, cursor(String)
}

/// The exact filter identity used by an event cursor.
public enum TaskEventKindSelection: Equatable, Sendable {
    case all, `default`, kinds([String])

    // Bound native argv admission independently of the producer's record/document bounds.
    var normalized: TaskEventKindSelection? {
        guard case .kinds(let names) = self else { return self }
        guard !names.isEmpty, names.count <= 200,
              names.allSatisfy({ !$0.isEmpty && !$0.contains(",") && !$0.contains("\0") }),
              names.reduce(0, { $0 + $1.utf8.count }) <= 16384 else { return nil }
        return .kinds(Array(Set(names)).sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) })
    }

    var echo: JSONValue {
        switch self {
        case .all: return .string("all")
        case .default: return .string("default")
        case .kinds(let names): return .array(names.map(JSONValue.string))
        }
    }

    var options: [String] {
        switch self {
        case .all: return ["--all-kinds"]
        case .default: return []
        case .kinds(let names): return ["--kinds=\(names.joined(separator: ","))"]
        }
    }
}

// MARK: - TaskEventLog

/// Lifecycle evidence is independent of history coverage or cursor progress.
public struct TaskEventLog: Equatable, Sendable {
    /// Only known states can be interpreted; final does not imply complete history.
    public enum State: String, Equatable, Sendable {
        case open, final, settling, incomplete, unknown, unavailable
    }

    public let state: State
    public let taskStatus: String
    public let captureState: String
    public let outputDrained: Bool
    public let finalSeq: Int?
    public let raw: [String: JSONValue]

    init?(raw: [String: JSONValue]) {
        guard let name = raw["state"]?.stringValue, let state = State(rawValue: name),
              let status = raw["task_status"]?.stringValue,
              let capture = raw["capture_state"]?.stringValue,
              let drained = raw["output_drained"]?.boolValue,
              TaskEventPage.nullableInteger(raw["final_seq"]) else { return nil }
        let final = raw["final_seq"]?.wireIntegerValue
        guard state == .final ? (drained && final != nil) : final == nil else { return nil }
        self.state = state
        taskStatus = status
        captureState = capture
        outputDrained = drained
        finalSeq = final
        self.raw = raw
    }
}

/// Endpoints of accounted records in file order; endpoints may regress.
public struct TaskEventSpan: Equatable, Sendable {
    public let firstSeq: Int
    public let lastSeq: Int
    public let raw: [String: JSONValue]

    init?(raw: [String: JSONValue]) {
        guard let first = raw["first_seq"]?.wireIntegerValue, first >= 0,
              let last = raw["last_seq"]?.wireIntegerValue, last >= 0 else { return nil }
        firstSeq = first
        lastSeq = last
        self.raw = raw
    }
}

/// Best-effort skipped line/window counts, which are not bounded by returned record count.
public struct TaskEventSkipped: Equatable, Sendable {
    public let malformed: Int
    public let oversized: Int
    public let raw: [String: JSONValue]

    init?(raw: [String: JSONValue]) {
        guard let malformed = raw["malformed"]?.wireIntegerValue, malformed >= 0,
              let oversized = raw["oversized"]?.wireIntegerValue, oversized >= 0 else { return nil }
        self.malformed = malformed
        self.oversized = oversized
        self.raw = raw
    }
}

/// Unaccounted sequence interval; unknown reason values remain available verbatim.
public struct TaskEventGap: Equatable, Sendable {
    public let afterSeq: Int
    public let beforeSeq: Int
    public let reason: String
    public let raw: [String: JSONValue]

    init?(raw: [String: JSONValue]) {
        guard let after = raw["after_seq"]?.wireIntegerValue, after >= 0,
              let before = raw["before_seq"]?.wireIntegerValue, before >= 0,
              let reason = raw["reason"]?.stringValue else { return nil }
        afterSeq = after
        beforeSeq = before
        self.reason = reason
        self.raw = raw
    }
}

/// Explicit prefix resolution provenance, separate from the requested identifier.
public struct TaskEventResolvedFrom: Equatable, Sendable {
    public let input: String
    public let taskID: String
    public let raw: [String: JSONValue]

    init?(raw: [String: JSONValue]) {
        guard let input = raw["input"]?.stringValue, !input.isEmpty,
              let taskID = raw["task_id"]?.stringValue, !taskID.isEmpty else { return nil }
        self.input = input
        self.taskID = taskID
        self.raw = raw
    }
}

// MARK: - TaskEventPage

/// One bounded public page. Raw payloads retain additive data and normalization loss.
public struct TaskEventPage: Equatable, Sendable {
    public let taskID: String
    public let order: String
    public let selection: TaskEventKindSelection
    public let events: [TaskEventRecord]
    public let olderCursor: String?
    public let newerCursor: String?
    public let hasOlder: Bool
    public let hasNewer: Bool
    public let span: TaskEventSpan?
    public let skipped: TaskEventSkipped
    public let gaps: [TaskEventGap]
    public let log: TaskEventLog
    public let changeToken: String
    public let observedAt: String
    public let observedDate: Date
    public let resolvedFrom: TaskEventResolvedFrom?
    public let raw: [String: JSONValue]

    /// Requires exact known fields and query echo; no legacy TaskEvent projection is performed.
    public init?(raw: [String: JSONValue], limit: Int = 100, selection: TaskEventKindSelection = .all) {
        guard (1 ... 200).contains(limit), let selection = selection.normalized,
              raw["kinds"] == selection.echo,
              let taskID = raw["task_id"]?.stringValue, !taskID.isEmpty,
              raw["order"]?.stringValue == "ascending",
              let records = raw["events"]?.arrayValue, records.count <= limit,
              Self.nullableCursor(raw["older_cursor"]), Self.nullableCursor(raw["newer_cursor"]),
              let hasOlder = raw["has_older"]?.boolValue, let hasNewer = raw["has_newer"]?.boolValue,
              let skippedRaw = raw["skipped"]?.objectValue, let skipped = TaskEventSkipped(raw: skippedRaw),
              let gapsRaw = raw["gaps"]?.arrayValue, gapsRaw.count <= limit,
              let logRaw = raw["log"]?.objectValue, let log = TaskEventLog(raw: logRaw),
              let token = raw["change_token"]?.stringValue,
              let observed = raw["observed_at"]?.stringValue, let date = Self.utcDate(observed) else { return nil }
        let events = records.compactMap { $0.objectValue.flatMap(TaskEventRecord.init(raw:)) }
        let gaps = gapsRaw.compactMap { $0.objectValue.flatMap(TaskEventGap.init(raw:)) }
        guard events.count == records.count, gaps.count == gapsRaw.count else { return nil }
        var span: TaskEventSpan?
        if raw["span"] != .null {
            guard let object = raw["span"]?.objectValue, let decoded = TaskEventSpan(raw: object) else { return nil }
            span = decoded
        }
        var resolution: TaskEventResolvedFrom?
        if let value = raw["resolved_from"] {
            guard let object = value.objectValue, let decoded = TaskEventResolvedFrom(raw: object) else { return nil }
            resolution = decoded
        }
        let older = raw["older_cursor"]?.stringValue
        let newer = raw["newer_cursor"]?.stringValue
        guard hasOlder == (older != nil), span != nil || (events.isEmpty && gaps.isEmpty) else { return nil }
        if log.state == .unavailable {
            guard newer == nil, older == nil, !hasOlder, !hasNewer, events.isEmpty, span == nil,
                  gaps.isEmpty, skipped.malformed == 0, skipped.oversized == 0 else { return nil }
        } else if newer == nil { return nil }
        self.taskID = taskID
        order = "ascending"
        self.selection = selection
        self.events = events
        olderCursor = older
        newerCursor = newer
        self.hasOlder = hasOlder
        self.hasNewer = hasNewer
        self.span = span
        self.skipped = skipped
        self.gaps = gaps
        self.log = log
        changeToken = token
        observedAt = observed
        observedDate = date
        resolvedFrom = resolution
        self.raw = raw
    }

    static func nullableInteger(_ value: JSONValue?) -> Bool {
        value == .null || value?.wireIntegerValue.map { $0 >= 0 } == true
    }

    static func validCursor(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.count <= 2048 && !value.contains("\0")
    }

    private static func nullableCursor(_ value: JSONValue?) -> Bool {
        value == .null || value?.stringValue.map(validCursor) == true
    }

    private static func utcDate(_ value: String) -> Date? {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|\+00:00)$"#,
                          options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

// MARK: - CtlClient task events

public extension CtlClient {
    /// Reads a public page after a fresh ctl/events and operation-capability handshake.
    func taskEvents(taskID: String, position: TaskEventPagePosition = .newest, limit: Int = 100,
                    selection: TaskEventKindSelection = .all) async -> Result<TaskEventPage, ToolError> {
        guard (1 ... 200).contains(limit), let selection = selection.normalized else {
            return .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Invalid task-events limit or kind selection"))
        }
        var options = ["--limit=\(limit)"] + selection.options
        switch position {
        case .newest: options.append("--from=newest")
        case .oldest: options.append("--from=oldest")
        case .cursor(let cursor):
            guard TaskEventPage.validCursor(cursor) else {
                return .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Invalid task-events cursor"))
            }
            options.append("--cursor=\(cursor)")
        }
        let response = await result("task-events", options: options, positionals: [taskID], requiringCapability: CtlCapability.taskEventPage)
        guard !Task.isCancelled, operationIsCurrent() else {
            return .failure(WireEnvelope.incompatibility("task-events operation superseded"))
        }
        return response.flatMap { raw in
            guard let page = TaskEventPage(raw: raw, limit: limit, selection: selection),
                  Self.eventIdentityMatches(page, requested: taskID) else {
                return .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Malformed task-events result or mismatched task identity"))
            }
            return .success(page)
        }
    }

    private static func eventIdentityMatches(_ page: TaskEventPage, requested: String) -> Bool {
        if let resolved = page.resolvedFrom {
            return resolved.input == requested && resolved.taskID == page.taskID
                && requested.count >= 8 && page.taskID != requested && page.taskID.hasPrefix(requested)
        }
        return page.taskID == requested
    }
}
