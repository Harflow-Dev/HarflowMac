import MonitorCore

// MARK: - CtlClient MCP approvals

public extension CtlClient {
    /// Reads or changes one global MCP approval through the CLI; never edits harness files directly.
    func mcpAllowlist(backend: String, allow: String? = nil, remove: String? = nil) async -> Result<[String: JSONValue], ToolError> {
        var options = ["--backend=\(backend)"]
        if let allow { options.append("--allow=\(allow)") }
        if let remove { options.append("--remove=\(remove)") }
        let output = await runner.run(executable: executable, arguments: Self.argv("mcp-allowlist", options: options),
                                      environment: environment, currentDirectory: nil, timeout: 25)
        return output.flatMap { output in
            if output.timedOut { return .failure(.timedOut(tool: "polybridge-ctl mcp-allowlist", seconds: 25)) }
            return CtlDocument.decode(stdout: output.stdout, stderr: output.stderr, exitCode: output.exitCode, command: "mcp-allowlist")
                .requiringSuccess()
.flatMap { document in
                    if case .result(let payload) = document { return .success(payload) }
                    return .failure(.unreadable(tool: "polybridge-ctl", exitCode: output.exitCode, stderr: "mcp-allowlist returned no result"))
                }
        }
    }
}
