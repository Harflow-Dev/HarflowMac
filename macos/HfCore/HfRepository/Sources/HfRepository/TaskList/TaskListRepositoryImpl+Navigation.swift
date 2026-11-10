import MonitorCore

// MARK: - TaskListRepositoryImpl navigation

extension TaskListRepositoryImpl {
    public func runningInSubtrees(of ids: [String]) -> [String] {
        var result: [String] = []
        var frontier = ids
        var seen = Set<String>()
        while let id = frontier.popLast() {
            guard seen.insert(id).inserted else { continue }
            if task(id)?.status.isRunning == true { result.append(id) }
            frontier.append(contentsOf: Lineage.children(of: id, in: tasksValue).map(\.taskID))
        }
        return result
    }

    /// Reads recorded successors through the same captured runtime, without adopting task history.
    public func successorPage(predecessorTaskID: String, cursor: String?, runtime: QualificationRuntimeToken) async throws -> TaskSuccessorPage {
        let client = try runtime.boundClient(tooling: toolEnvironment)
        let page = try await client.taskSuccessorPage(predecessorTaskID: predecessorTaskID, cursor: cursor).get()
        guard !Task.isCancelled, client.operationIsCurrent() else { throw QualificationSessionError.runtimeChanged }
        _ = try runtime.boundClient(tooling: toolEnvironment)
        return page
    }

}
