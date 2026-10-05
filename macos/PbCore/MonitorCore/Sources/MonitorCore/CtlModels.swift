import Foundation

/// The `"v"` values this app understands for `polybridge-ctl --json`. Anything else is refused
/// with a message naming the tool and the versions understood, never guessed at. v2 added
/// `resume_command` to `status`'s `task`/`list`'s `tasks[]` snapshot documents (Monitor piece 3/3);
/// v3 adds pending messages and workflow ownership/status fields; v4 adds workflow result errors; v5 adds nested workflow ownership.
/// Older versions remain accepted.
/// `polybridge-setup --json` and
/// `events.jsonl` are separate contracts with their own single-version constants — see
/// `setupContractVersion` (`SetupClient.swift`) and `eventLogVersion` (`Events.swift`) — because a
/// shape change to one of the three must never silently widen what the app accepts from the
/// others.
public let ctlContractVersions: Set<Int> = [1, 2, 3, 4, 5]

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
    /// Parsed once here: the listing is sorted by start time on every sidebar update, and parsing
    /// inside each comparison pinned the main thread on a large history.
    public let startedAt: Date?

    public init?(_ value: JSONValue) {
        guard let object = value.objectValue, let id = object["task_id"]?.stringValue, !id.isEmpty else {
            return nil
        }
        raw = object
        taskID = id
        startedAt = object["started_at"]?.stringValue.flatMap(ISODate.parse)
    }

    private func string(_ key: String) -> String? { raw[key]?.stringValue }

    public var backend: String { string("backend") ?? "unknown" }
    public var sessionID: String? { string("session_id") }
    public var repoPath: String { string("repo_path") ?? "" }
    public var status: TaskStatus { TaskStatus(string("status") ?? "unknown") }
    public var freedom: String? { string("freedom") }
    public var startedAtRaw: String? { string("started_at") }
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
    public var eventsLog: String? { string("events_log") }
    public var note: String? { string("note") }
    public var totalCostUSD: Double? { raw["total_cost_usd"]?.doubleValue }
    public var numTurns: Int? { raw["num_turns"]?.intValue }
    public var permissionDenials: [JSONValue] { raw["permission_denials"]?.arrayValue ?? [] }
    /// A ready-to-paste `cd <repo> && <argv>` command that resumes this task's session in a
    /// POSIX shell, computed by `backends.resume_command` (Monitor piece 3/3). `nil` for any
    /// non-string value and for an empty string alike — a null and an empty answer both mean
    /// "nothing to offer", so a caller only needs to check for `nil`.
    public var resumeCommand: String? { string("resume_command").flatMap { $0.isEmpty ? nil : $0 } }

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

/// One backend as `polybridge-ctl backends --json` reports it: its registered name, its binary, and
/// whether that binary is on the login PATH the Monitor runs `polybridge-ctl` with. `installed` is
/// `nil` — unknown — whenever the field is missing or not a bool, never silently `false`: a wrong
/// or absent answer must never read as a confirmed "not found" (Code review round 1, finding 1).
public struct BackendAvailability: Equatable, Sendable {
    public let backend: String
    public let binary: String
    public let installed: Bool?

    public init(backend: String, binary: String, installed: Bool?) {
        self.backend = backend
        self.binary = binary
        self.installed = installed
    }

    public init?(_ value: JSONValue) {
        guard let object = value.objectValue,
              let backend = object["backend"]?.stringValue, !backend.isEmpty,
              let binary = object["binary"]?.stringValue else { return nil }
        self.backend = backend
        self.binary = binary
        // `.boolValue` itself already answers `nil` for a missing key or a non-bool value — no
        // `?? false` fallback here, so either case reads as "unknown," never "confirmed absent."
        installed = object["installed"]?.boolValue
    }
}

public enum ISODate {
    // Built once: creating a formatter costs far more than parsing with one, and a large listing
    // parses a start time per task (this once froze the sidebar). `ISO8601DateFormatter` is
    // thread-safe, so sharing them is fine.
    private nonisolated(unsafe) static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Python's `datetime.isoformat()` with and without fractional seconds, and with a `+00:00`
    /// offset (which `ISO8601DateFormatter` accepts).
    public static func parse(_ text: String) -> Date? {
        if let date = withFraction.date(from: text) { return date }
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
            let understood = Self.understoodVersions(forTool: tool)
            let plural = understood.contains(" or ") || understood.contains(",")
            return "`\(tool)` answered with contract version \(version); this app understands version\(plural ? "s" : "") \(understood). "
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

    /// The versions understood for `tool`'s own contract, rendered for the unsupported-version
    /// message ("1 or 2", "1", …). Each tool has exactly one contract, so its name is enough to
    /// pick the right constant — see `ctlContractVersions`/`setupContractVersion`.
    fileprivate static func understoodVersions(forTool tool: String) -> String {
        switch tool {
        case "polybridge-ctl":
            return ctlContractVersions.sorted().map(String.init).joined(separator: " or ")
        case "polybridge-setup":
            return String(setupContractVersion)
        default:
            return String(eventLogVersion)
        }
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
    case backends([BackendAvailability])
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
        guard let versionInt = version.intValue, ctlContractVersions.contains(versionInt) else {
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
        if let known = knownDocument(document) {
            return .success(known)
        }
        return .failure(.unreadable(tool: tool, exitCode: exitCode, stderr: "unexpected document: \(JSONValue.object(document).rendered())"))
    }

    /// The document shapes that carry no error/version concerns of their own — pulled out of
    /// `decode(stdout:stderr:exitCode:command:)` so that function's own branching (the parts that
    /// actually need `tool`/`exitCode`/`command`) stays readable.
    private static func knownDocument(_ document: [String: JSONValue]) -> CtlDocument? {
        if let tasks = document["tasks"]?.arrayValue {
            return .tasks(tasks.compactMap(TaskInfo.init))
        }
        if let task = document["task"], let info = TaskInfo(task) {
            return .task(info)
        }
        if let backends = document["backends"]?.arrayValue {
            // A malformed entry (missing `backend`/`binary`) makes the whole document malformed —
            // never silently dropped via `compactMap`, which could otherwise clear New Session's
            // selection or disable Start on a partial answer (Code review round 1, finding 1). A
            // non-list `backends` value falls through this `if let` entirely and reaches the same
            // "unexpected document" failure below.
            var entries: [BackendAvailability] = []
            entries.reserveCapacity(backends.count)
            for item in backends {
                guard let entry = BackendAvailability(item) else { return nil }
                entries.append(entry)
            }
            return .backends(entries)
        }
        if let result = document["result"]?.objectValue {
            return .result(result)
        }
        if let unknown = document["unknown"]?.objectValue {
            return .unknown(unknown)
        }
        return nil
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
