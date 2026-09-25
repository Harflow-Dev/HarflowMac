import Foundation

/// The one `"v"` the app understands for `polybridge-ctl --json`, `polybridge-setup --json` and
/// `events.jsonl`. Anything else is refused with a message, never guessed at.
public let supportedContractVersion = 1

public enum TaskStatus: Equatable, Hashable, Sendable {
    case running, completed, failed, timedOut, cancelled
    case other(String)

    public init(_ raw: String) {
        switch raw {
        case "running": self = .running
        case "completed": self = .completed
        case "failed": self = .failed
        case "timed_out": self = .timedOut
        case "cancelled": self = .cancelled
        default: self = .other(raw)
        }
    }

    public var isRunning: Bool { self == .running }
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .timedOut, .cancelled: return true
        case .running, .other: return false
        }
    }

    public var label: String {
        switch self {
        case .running: return "Running"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .timedOut: return "Timed out"
        case .cancelled: return "Cancelled"
        case .other(let raw): return raw
        }
    }
}

/// One task as `polybridge-ctl list --json` (brief) or `status --json` (snapshot) reports it.
/// Built leniently from the raw object: only `task_id` is required, every other field may be
/// absent (older records, older ctl). `raw` keeps the whole object for the Details panel.
public struct TaskInfo: Equatable, Identifiable, Sendable {
    public let raw: [String: JSONValue]

    public var id: String { taskID }
    public let taskID: String

    public init?(_ value: JSONValue) {
        guard let object = value.objectValue, let id = object["task_id"]?.stringValue, !id.isEmpty else {
            return nil
        }
        raw = object
        taskID = id
    }

    private func string(_ key: String) -> String? { raw[key]?.stringValue }

    public var backend: String { string("backend") ?? "unknown" }
    public var sessionID: String? { string("session_id") }
    public var repoPath: String { string("repo_path") ?? "" }
    public var status: TaskStatus { TaskStatus(string("status") ?? "unknown") }
    public var freedom: String? { string("freedom") }
    public var startedAtRaw: String? { string("started_at") }
    public var startedAt: Date? { startedAtRaw.flatMap(ISODate.parse) }
    public var durationSeconds: Double? { raw["duration_seconds"]?.doubleValue }
    public var parentTaskID: String? { string("parent_task_id") }
    public var spawnedBy: String? { string("spawned_by") }
    public var rootTaskID: String? { string("root_task_id") }
    public var depth: Int { raw["depth"]?.intValue ?? 0 }
    public var maxDepth: Int? { raw["max_depth"]?.intValue }
    public var group: String? { string("group").flatMap { $0.isEmpty ? nil : $0 } }
    public var lineageDetected: String? { string("lineage_detected") }
    public var liveInput: Bool { raw["live_input"]?.boolValue ?? false }
    public var notices: [String] { raw["notices"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    public var takenOver: Bool { raw["taken_over"]?.boolValue ?? false }
    public var takenOverNote: String? { string("taken_over_note") }
    public var ownedByLiveServer: Bool? { raw["owned_by_live_server"]?.boolValue }
    public var recovered: Bool { raw["recovered"]?.boolValue ?? false }

    // Snapshot-only fields (nil in a `list` brief).
    public var summary: String? { string("summary") }
    public var isError: Bool? { raw["is_error"]?.boolValue }
    public var exitCode: Int? { raw["exit_code"]?.intValue }
    public var model: String? { string("model") }
    public var reasoningEffort: String? { string("reasoning_effort") }
    public var enforcement: [String: JSONValue]? { raw["enforcement"]?.objectValue }
    public var baseCommit: String? { string("base_commit") }
    public var startDirty: Bool? { raw["start_dirty"]?.boolValue }
    public var eventsLog: String? { string("events_log") }
    public var note: String? { string("note") }
    public var totalCostUSD: Double? { raw["total_cost_usd"]?.doubleValue }
    public var numTurns: Int? { raw["num_turns"]?.intValue }
    public var permissionDenials: [JSONValue] { raw["permission_denials"]?.arrayValue ?? [] }

    /// A root task: no detected caller. `depth` alone is not enough — a record written before
    /// lineage existed has depth 0 and no `spawned_by` either, which is also a root.
    public var isRoot: Bool { spawnedBy == nil && depth == 0 }

    /// Seconds the task has run: the recorded duration once settled, else measured from start.
    public func elapsed(now: Date = Date()) -> TimeInterval? {
        if !status.isRunning, let durationSeconds { return durationSeconds }
        if let startedAt { return max(0, now.timeIntervalSince(startedAt)) }
        return durationSeconds
    }
}

public enum ISODate {
    /// Python's `datetime.isoformat()` with and without fractional seconds, and with a `+00:00`
    /// offset (which `ISO8601DateFormatter` accepts).
    public static func parse(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        // Python writes microseconds (6 digits); the formatter only takes up to 3 on some systems.
        if let dot = text.firstIndex(of: "."), let zoneStart = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let fraction = text[text.index(after: dot)..<zoneStart]
            let trimmed = text[..<dot] + "." + fraction.prefix(3) + text[zoneStart...]
            return withFraction.date(from: String(trimmed))
        }
        return nil
    }
}

/// Everything that can go wrong asking `polybridge-ctl` or `polybridge-setup` something, each
/// with a message a person can act on.
public enum ToolError: Error, Equatable, Sendable {
    /// The binary was not found in any searched directory.
    case notFound(tool: String, searched: [String])
    /// The binary answered with a `"v"` this app does not know.
    case unsupportedVersion(tool: String, version: String)
    /// The binary does not have this subcommand — an older polybridge install.
    case unsupportedCommand(tool: String, command: String, detail: String)
    /// Stdout was not one JSON document.
    case unreadable(tool: String, exitCode: Int32, stderr: String)
    /// The command ran and refused, with polybridge's own stable code.
    case refused(code: String, message: String)
    /// A `run`/`resume` whose owner never answered: a task may or may not exist.
    case unknownOutcome(message: String)
    case launchFailed(tool: String, detail: String)
    case timedOut(tool: String, seconds: Double)

    public var message: String {
        switch self {
        case .notFound(let tool, let searched):
            return "`\(tool)` was not found (searched \(searched.joined(separator: ", "))). "
                + "Install polybridge (`uv tool install . --force --no-cache` in the repo) or set its folder in Settings."
        case .unsupportedVersion(let tool, let version):
            return "`\(tool)` answered with contract version \(version); this app understands version \(supportedContractVersion). "
                + "Update the app or polybridge so they match."
        case .unsupportedCommand(let tool, let command, _):
            return "The installed `\(tool)` has no `\(command)` command — it predates this app. "
                + "Reinstall polybridge from the repo (`uv tool install . --force --no-cache`)."
        case .unreadable(let tool, let exitCode, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "`\(tool)` exited \(exitCode) without a JSON answer"
                + (detail.isEmpty ? "." : ": \(detail.suffix(400))")
        case .refused(let code, let message):
            return TakeoverRefusal.explanation(code: code, message: message)
        case .unknownOutcome(let message):
            return message.isEmpty ? "No answer from polybridge; check the task list." : message
        case .launchFailed(let tool, let detail):
            return "Could not run `\(tool)`: \(detail)"
        case .timedOut(let tool, let seconds):
            return "`\(tool)` did not answer within \(Int(seconds)) s."
        }
    }

    public var refusalCode: String? {
        if case .refused(let code, _) = self { return code }
        return nil
    }
}

/// Human wording for the refusal codes `polybridge-ctl` can return. The ctl message is always kept:
/// it carries the specifics (which task, which process).
public enum TakeoverRefusal {
    public static func headline(code: String) -> String? {
        switch code {
        case "agent_caller":
            return "Refused: this request came from inside an agent task. Take over is for a person at the Monitor."
        case "caller_undecidable":
            return "Refused: polybridge could not confirm this request is not coming from an agent task, so it refuses rather than guess."
        case "descendants_not_stopped":
            return "Refused: a sub-task of this task could not be confirmed stopped, so the session was not handed over."
        case "not_stopped":
            return "Refused: the headless run could not be confirmed stopped."
        case "session_busy":
            return "Refused: another run or takeover is using this session."
        case "binary_not_found":
            return "Refused: the agent's command line tool is not on your login PATH."
        case "no_session":
            return "Refused: the task never reported a session id, so there is nothing to resume."
        case "no_interactive_command":
            return "Refused: this backend cannot resume this session interactively."
        case "repo_unavailable":
            return "Refused: the task's repository folder no longer exists."
        case "not_ready":
            return "Refused: there is no takeover waiting for a terminal."
        case "window_expired":
            return "Refused: the terminal attached too late; the takeover window lapsed."
        case "already_attached":
            return "Refused: a terminal is already attached to this takeover."
        case "pid_not_found":
            return "Refused: the terminal's process could not be identified."
        case "unknown_task":
            return "This task is not on disk any more."
        case "closed", "settled", "exited":
            return "This task no longer takes messages; use Continue once it has finished."
        case "not_live_input":
            return "This task was not started with live input, so it cannot take messages."
        case "owner_not_alive":
            return "The server that owns this task is not confirmed alive, so the message could not be queued."
        default:
            return nil
        }
    }

    public static func explanation(code: String, message: String) -> String {
        guard let headline = headline(code: code) else {
            return message.isEmpty ? "Refused (\(code))." : "\(message) (\(code))"
        }
        return message.isEmpty ? headline : "\(headline)\n\(message)"
    }
}

/// A decoded `polybridge-ctl --json` document.
public enum CtlDocument: Equatable, Sendable {
    case tasks([TaskInfo])
    case task(TaskInfo)
    case result([String: JSONValue])
    case unknown([String: JSONValue])
    case error(code: String, message: String)

    /// Decode stdout of `polybridge-ctl <command> --json`. `command` is only used in messages.
    public static func decode(stdout: Data, stderr: String, exitCode: Int32, command: String) -> Result<CtlDocument, ToolError> {
        let tool = "polybridge-ctl"
        guard let document = firstJSONObject(in: stdout) else {
            // An older ctl without this subcommand exits 2 from argparse, and may not know
            // `--json` at all, so its complaint is on stderr in prose.
            if exitCode == 2, stderr.contains("invalid choice") {
                return .failure(.unsupportedCommand(tool: tool, command: command, detail: stderr))
            }
            return .failure(.unreadable(tool: tool, exitCode: exitCode, stderr: stderr))
        }
        guard let version = document["v"] else {
            return .failure(.unsupportedVersion(tool: tool, version: "none"))
        }
        guard version.intValue == supportedContractVersion else {
            return .failure(.unsupportedVersion(tool: tool, version: version.rendered()))
        }
        if let error = document["error"]?.objectValue {
            let code = error["code"]?.stringValue ?? "error"
            let message = error["message"]?.stringValue ?? ""
            if code == "usage", message.contains("invalid choice") || message.contains("unrecognized arguments") {
                return .failure(.unsupportedCommand(tool: tool, command: command, detail: message))
            }
            return .success(.error(code: code, message: message))
        }
        if let tasks = document["tasks"]?.arrayValue {
            return .success(.tasks(tasks.compactMap(TaskInfo.init)))
        }
        if let task = document["task"], let info = TaskInfo(task) {
            return .success(.task(info))
        }
        if let result = document["result"]?.objectValue {
            return .success(.result(result))
        }
        if let unknown = document["unknown"]?.objectValue {
            return .success(.unknown(unknown))
        }
        return .failure(.unreadable(tool: tool, exitCode: exitCode, stderr: "unexpected document: \(JSONValue.object(document).rendered())"))
    }

    /// The document on stdout. polybridge prints exactly one; tolerate leading blank lines.
    static func firstJSONObject(in data: Data) -> [String: JSONValue]? {
        if let whole = JSONValue.parse(data)?.objectValue { return whole }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            if let object = JSONValue.parse(Data(line.utf8))?.objectValue { return object }
        }
        return nil
    }
}

extension Result where Failure == ToolError {
    /// Collapse a ctl `error` document into a failure, so callers only see a success when the
    /// command did what was asked.
    public func requiringSuccess() -> Result<CtlDocument, ToolError> where Success == CtlDocument {
        flatMap { document in
            switch document {
            case .error(let code, let message): return .failure(.refused(code: code, message: message))
            case .unknown(let payload): return .failure(.unknownOutcome(message: payload["message"]?.stringValue ?? ""))
            default: return .success(document)
            }
        }
    }
}
