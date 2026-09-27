import Foundation

/// The one `"v"` this app understands for `polybridge-setup --json` — a contract separate from
/// `polybridge-ctl`'s (`ctlContractVersions`, `CtlModels.swift`) and the event log's
/// (`eventLogVersion`, `Events.swift`), so a shape change to one never silently widens what the
/// app accepts from the others.
public let setupContractVersion = 1

/// One row of `polybridge-setup --json`: one MCP client (harness) that can launch polybridge.
public struct HarnessRow: Equatable, Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let available: Bool
    /// nil means setup could not tell, never "not installed".
    public let installed: Bool?
    public let command: String?
    public let current: Bool?
    public let action: String?
    public let error: String?
    public let notes: [String]

    init?(_ value: JSONValue) {
        guard let object = value.objectValue, let key = object["key"]?.stringValue else { return nil }
        self.key = key
        available = object["available"]?.boolValue ?? false
        installed = object["installed"]?.boolValue
        command = object["command"]?.stringValue
        current = object["current"]?.boolValue
        action = object["action"]?.stringValue
        error = object["error"]?.stringValue
        notes = object["notes"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    public var displayName: String {
        switch key {
        case "claude-desktop": return "Claude Desktop"
        case "claude-code": return "Claude Code"
        case "codex": return "Codex"
        case "opencode": return "opencode"
        case "vibe": return "vibe"
        default: return key
        }
    }

    public var stateLabel: String {
        switch installed {
        case .some(true): return current == false ? "Installed · out of date" : "Installed"
        case .some(false): return available ? "Not installed" : "Not found on this Mac"
        case .none: return "Unknown"
        }
    }
}

public struct SetupDocument: Equatable, Sendable {
    public let serverPath: String?
    public let rows: [HarnessRow]

    /// setup's exit code reflects the rows (a failed client exits non-zero with a full document),
    /// so the document, not the exit code, is the answer.
    public static func decode(stdout: Data, stderr: String, exitCode: Int32) -> Result<SetupDocument, ToolError> {
        let tool = "polybridge-setup"
        guard let document = CtlDocument.firstJSONObject(in: stdout) else {
            if exitCode == 2, stderr.contains("unrecognized arguments") || stderr.contains("invalid choice") {
                return .failure(.unsupportedCommand(tool: tool, command: "--json", detail: stderr))
            }
            return .failure(.unreadable(tool: tool, exitCode: exitCode, stderr: stderr))
        }
        guard let version = document["v"]?.intValue else {
            return .failure(.unsupportedVersion(tool: tool, version: document["v"]?.rendered() ?? "none"))
        }
        guard version == setupContractVersion else {
            return .failure(.unsupportedVersion(tool: tool, version: String(version)))
        }
        guard let rows = document["clients"]?.arrayValue else {
            return .failure(.unreadable(tool: tool, exitCode: exitCode, stderr: "no clients array"))
        }
        return .success(SetupDocument(serverPath: document["server_path"]?.stringValue, rows: rows.compactMap(HarnessRow.init)))
    }
}

/// `polybridge-setup`, called only when the user asks (opening Settings → Harnesses, or clicking
/// Install / Remove on a row). Install and Remove change another app's config.
public struct SetupClient: Sendable {
    public var executable: String
    public var environment: [String: String]
    public var runner: ProcessRunning

    public init(executable: String, environment: [String: String], runner: ProcessRunning = ProcessRunner()) {
        self.executable = executable
        self.environment = environment
        self.runner = runner
    }

    public enum Action: Sendable { case status, install, remove }

    public static func arguments(_ action: Action, client: String?) -> [String] {
        var args: [String] = []
        switch action {
        case .status: args.append("--status")
        case .install: break
        case .remove: args.append("--uninstall")
        }
        if let client { args.append("--client=\(client)") }
        args.append("--json")
        return args
    }

    public func perform(_ action: Action, client: String? = nil) async -> Result<SetupDocument, ToolError> {
        let output = await runner.run(executable: executable, arguments: Self.arguments(action, client: client), environment: environment, currentDirectory: nil, timeout: 90)
        return output.flatMap { output in
            if output.timedOut { return .failure(.timedOut(tool: "polybridge-setup", seconds: 90)) }
            return SetupDocument.decode(stdout: output.stdout, stderr: output.stderr, exitCode: output.exitCode)
        }
    }
}
