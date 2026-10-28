// MARK: - ToolError unsupported commands

extension ToolError {
    /// Only the exact locally generated capability refusal changes the existing usage-error copy.
    static func unsupportedCommandMessage(tool: String, command: String, detail: String) -> String {
        if detail == "Missing capability messaging.v1" {
            return "The installed `\(tool)` does not support capability `messaging.v1`, required for `\(command)`. "
                + "Use a compatible managed Harflow runtime."
        }
        return "The installed `\(tool)` has no `\(command)` command — it predates this app. "
            + "Use a compatible managed Harflow runtime."
    }
}
