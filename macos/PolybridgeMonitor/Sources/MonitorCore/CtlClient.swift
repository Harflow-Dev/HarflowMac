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

    // ctl's own `run`/`resume` handshake waits 30 s; `takeover` may cascade-cancel a live tree and
    // hold for phase writes, so it gets well past ctl's 60 s settle window.
    static let quickTimeout = 30.0
    static let startTimeout = 45.0
    static let takeoverTimeout = 120.0

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

    public func takeoverAttach(_ taskID: String, pid: Int32) async -> Result<[String: JSONValue], ToolError> {
        await result("takeover-attach", options: ["--pid=\(pid)"], positionals: [taskID])
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

    public init(backend: String, repo: String, prompt: String, freedom: String? = nil, reasoningEffort: String? = nil, group: String? = nil) {
        self.backend = backend
        self.repo = repo
        self.prompt = prompt
        self.freedom = freedom
        self.reasoningEffort = reasoningEffort
        self.group = group
    }

    /// `--opt=value` form throughout, so a prompt starting with `-` can never be read as an option.
    public var arguments: [String] {
        var args = ["--backend=\(backend)", "--repo=\(repo)", "--prompt=\(prompt)"]
        if let freedom, !freedom.isEmpty { args.append("--freedom=\(freedom)") }
        if let reasoningEffort, !reasoningEffort.isEmpty { args.append("--reasoning-effort=\(reasoningEffort)") }
        if let group, !group.isEmpty { args.append("--group=\(group)") }
        return args
    }
}
