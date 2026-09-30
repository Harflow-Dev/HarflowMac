import Foundation

/// The app's only way to act on polybridge: `polybridge-ctl` subcommands, one JSON document each.
/// The app never writes polybridge state itself.
public struct CtlClient: Sendable {
    public var executable: String
    public var environment: [String: String]
    public var runner: ProcessRunning

    public init(executable: String, environment: [String: String], runner: ProcessRunning = ProcessRunner()) {
        self.executable = executable
        self.environment = environment
        self.runner = runner
    }

    // `run`/`resume` must outlast ctl's own worst case so ctl, not this timeout, gets the last word:
    // its handshake waits 30 s, then it may spend up to 15 s reaping the child and 5 s releasing
    // before it prints the structured "a task may already exist" answer (`detached.py`). Cut short,
    // that warning becomes a bare timeout and a retry can start the run twice (Codex PR review).
    // `cancel` and `takeover` run a shielded cascade across a live tree — up to 5 rounds, each up to
    // ~15 s before hand-off plus ~10 s per batch — then settle phase writes for up to 60 s, and
    // takeover may also wait 30 s on session locks. Killing ctl inside that leaves some tasks
    // stopped and later descendants abandoned behind a bare timeout (Codex PR review), so the
    // bound sits above the whole path.
    static let quickTimeout = 30.0
    static let startTimeout = 75.0
    static let takeoverTimeout = 300.0

    /// Options (always `--name=value`) go before `--json`; positionals after a `--`, so a message
    /// or id beginning with `-` can never be parsed as an option.
    public static func argv(_ command: String, options: [String] = [], positionals: [String] = []) -> [String] {
        [command] + options + ["--json"] + (positionals.isEmpty ? [] : ["--"] + positionals)
    }

    func call(_ command: String, options: [String] = [], positionals: [String] = [], timeout: Double = quickTimeout) async -> Result<CtlDocument, ToolError> {
        let argv = Self.argv(command, options: options, positionals: positionals)
        let output = await runner.run(executable: executable, arguments: argv, environment: environment, currentDirectory: nil, timeout: timeout)
        return output.flatMap { output in
            if output.timedOut { return .failure(.timedOut(tool: "polybridge-ctl \(command)", seconds: timeout)) }
            return CtlDocument.decode(stdout: output.stdout, stderr: output.stderr, exitCode: output.exitCode, command: command)
        }
    }

    public func list() async -> Result<[TaskInfo], ToolError> {
        await call("list").requiringSuccess().flatMap { document in
            if case .tasks(let tasks) = document { return .success(tasks) }
            return .failure(.unreadable(tool: "polybridge-ctl", exitCode: 0, stderr: "list returned no task array"))
        }
    }

    public func status(_ taskID: String) async -> Result<TaskInfo, ToolError> {
        await call("status", positionals: [taskID]).requiringSuccess().flatMap { document in
            if case .task(let task) = document { return .success(task) }
            return .failure(.unreadable(tool: "polybridge-ctl", exitCode: 0, stderr: "status returned no task"))
        }
    }

    /// `polybridge-ctl backends --json` — the registered backends and whether each is on PATH, in
    /// registry order. An older ctl without this command surfaces as `.unsupportedCommand`, which
    /// `CtlDocument.decode` already classifies before this ever sees a `.error` document — the same
    /// path `list()`/`status(_:)` rely on.
    public func backends() async -> Result<[BackendAvailability], ToolError> {
        await call("backends").requiringSuccess().flatMap { document in
            if case .backends(let items) = document { return .success(items) }
            return .failure(.unreadable(tool: "polybridge-ctl", exitCode: 0, stderr: "backends returned no array"))
        }
    }

    public func send(_ taskID: String, text: String) async -> Result<[String: JSONValue], ToolError> {
        await result("send", positionals: [taskID, text])
    }

    public func cancel(_ taskID: String) async -> Result<[String: JSONValue], ToolError> {
        await result("cancel", positionals: [taskID], timeout: Self.takeoverTimeout)
    }

    public func takeover(_ taskID: String) async -> Result<TakeoverGrant, ToolError> {
        await result("takeover", positionals: [taskID], timeout: Self.takeoverTimeout).flatMap { payload in
            guard let grant = TakeoverGrant(payload) else {
                return .failure(.unreadable(tool: "polybridge-ctl", exitCode: 0, stderr: "takeover returned no argv/cwd"))
            }
            return .success(grant)
        }
    }

    public func run(_ request: RunRequest) async -> Result<String, ToolError> {
        await result("run", options: request.arguments, timeout: Self.startTimeout).flatMap(Self.taskID)
    }

    public func resume(_ taskID: String, text: String) async -> Result<String, ToolError> {
        await result("resume", positionals: [taskID, text], timeout: Self.startTimeout).flatMap(Self.taskID)
    }

    static func taskID(_ payload: [String: JSONValue]) -> Result<String, ToolError> {
        guard let id = payload["task_id"]?.stringValue else {
            return .failure(.unreadable(tool: "polybridge-ctl", exitCode: 0, stderr: "no task_id in the answer"))
        }
        return .success(id)
    }

    func result(_ command: String, options: [String] = [], positionals: [String] = [], timeout: Double = quickTimeout) async -> Result<[String: JSONValue], ToolError> {
        await call(command, options: options, positionals: positionals, timeout: timeout).requiringSuccess().flatMap { document in
            if case .result(let payload) = document { return .success(payload) }
            return .failure(.unreadable(tool: "polybridge-ctl", exitCode: 0, stderr: "\(command) returned no result"))
        }
    }
}

/// What `polybridge-ctl takeover` hands back: the interactive command, never joined into text.
public struct TakeoverGrant: Equatable, Sendable {
    public let argv: [String]
    public let cwd: String
    public let sessionID: String?
    public let note: String

    public init?(_ payload: [String: JSONValue]) {
        guard let argv = payload["argv"]?.arrayValue?.compactMap(\.stringValue), !argv.isEmpty,
              argv.count == payload["argv"]?.arrayValue?.count,
              let cwd = payload["cwd"]?.stringValue, !cwd.isEmpty else { return nil }
        self.argv = argv
        self.cwd = cwd
        sessionID = payload["session_id"]?.stringValue
        note = payload["note"]?.stringValue ?? ""
    }

    public init(argv: [String], cwd: String, sessionID: String?, note: String) {
        self.argv = argv
        self.cwd = cwd
        self.sessionID = sessionID
        self.note = note
    }
}

public struct RunRequest: Equatable, Sendable {
    public var backend: String
    public var repo: String
    public var prompt: String
    public var freedom: String?
    public var reasoningEffort: String?
    public var group: String?
    /// Shown in the sidebar in place of a prompt-derived title (`ctl run --title`).
    public var title: String?
    /// The backend's own model name; `nil` or empty keeps the agent's default.
    public var model: String?
    public var maxTurns: Int?

    public init(
        backend: String, repo: String, prompt: String, freedom: String? = nil, reasoningEffort: String? = nil, group: String? = nil,
        title: String? = nil, model: String? = nil, maxTurns: Int? = nil
    ) {
        self.backend = backend
        self.repo = repo
        self.prompt = prompt
        self.freedom = freedom
        self.reasoningEffort = reasoningEffort
        self.group = group
        self.title = title
        self.model = model
        self.maxTurns = maxTurns
    }

    /// `--opt=value` form throughout, so a prompt starting with `-` can never be read as an option.
    public var arguments: [String] {
        var args = ["--backend=\(backend)", "--repo=\(repo)", "--prompt=\(prompt)"]
        if let freedom, !freedom.isEmpty { args.append("--freedom=\(freedom)") }
        if let reasoningEffort, !reasoningEffort.isEmpty { args.append("--reasoning-effort=\(reasoningEffort)") }
        if let group, !group.isEmpty { args.append("--group=\(group)") }
        if let title, !title.isEmpty { args.append("--title=\(title)") }
        if let model, !model.isEmpty { args.append("--model=\(model)") }
        if let maxTurns { args.append("--max-turns=\(maxTurns)") }
        return args
    }
}
