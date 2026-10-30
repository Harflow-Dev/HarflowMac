import Foundation

public extension CtlClient {
    /// `status-batch` with a per-id outcome and no fallback to per-id reads. A whole-command
    /// failure (including an engine without the command) is returned as the failure, so the
    /// caller can treat every id of the pass as unreadable. An id missing from both `tasks` and
    /// `errors` is reported as unreadable rather than assumed absent.
    func statusBatchOutcomes(ids: [String]) async -> Result<[String: Result<TaskInfo, ToolError>], ToolError> {
        let bounded = Array(ids.prefix(100))
        guard !bounded.isEmpty else { return .success([:]) }
        return await statusBatch(ids: bounded).map { batch in
            var outcomes: [String: Result<TaskInfo, ToolError>] = [:]
            for task in batch.tasks { outcomes[task.taskID] = .success(task) }
            for id in bounded where outcomes[id] == nil {
                if let error = batch.errors[id] {
                    outcomes[id] = .failure(.refused(code: error.code, message: error.message))
                } else {
                    outcomes[id] = .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "status-batch omitted \(id)"))
                }
            }
            return outcomes
        }
    }
}
