import MonitorCore

// MARK: - WorkflowRepository History

public extension WorkflowRepository {
    /// Reads one bounded, active-first history page for frequent status polling.
    /// Older history can be requested explicitly through the CLI's offset parameter.
    func historySummaries() async throws -> [[String: JSONValue]] {
        let page = try await command("list-runs", options: [], positionals: [])
        return page["runs"]?.arrayValue?.compactMap(\.objectValue) ?? []
    }
}
