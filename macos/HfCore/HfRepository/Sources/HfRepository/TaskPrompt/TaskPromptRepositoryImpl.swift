import MonitorCore

// MARK: - TaskPromptRepositoryImpl

/// Stateless prompt reads bound to the captured selected runtime and caller lifetime.
public struct TaskPromptRepositoryImpl: TaskPromptRepository {
    private let toolEnvironment: any ToolEnvironmentRepository
    private let stateRecovery: any StateRecoveryRepository

    public init(toolEnvironment: any ToolEnvironmentRepository, recovery: any StateRecoveryRepository) {
        self.toolEnvironment = toolEnvironment
        self.stateRecovery = recovery
    }

    public func read(taskID: String, maxBytes: Int,
                     operationIsCurrent: @escaping @Sendable () -> Bool) async -> Result<TaskPromptResult, ToolError> {
        guard !Task.isCancelled, operationIsCurrent() else { return .failure(Self.superseded) }
        let captured: CtlClient
        switch toolEnvironment.ctl() {
        case .success(let client): captured = client
        case .failure(let error):
            guard !Task.isCancelled, operationIsCurrent() else { return .failure(Self.superseded) }
            stateRecovery.report(error)
            return .failure(error)
        }
        let tooling = toolEnvironment
        let isCurrent: @Sendable () -> Bool = {
            guard !Task.isCancelled, captured.operationIsCurrent(), operationIsCurrent(),
                  case .success(let current) = tooling.ctl() else { return false }
            return current.executable == captured.executable
                && current.environment == captured.environment
                && current.compatibilityContext == captured.compatibilityContext
        }
        var client = captured
        client.operationIsCurrent = isCurrent
        guard isCurrent() else { return .failure(Self.superseded) }
        let response = await client.taskPrompt(taskID: taskID, maxBytes: maxBytes)
        guard isCurrent() else { return .failure(Self.superseded) }
        if case .failure(let error) = response { stateRecovery.report(error) }
        return response
    }

    private static var superseded: ToolError {
        .unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Task prompt operation superseded")
    }
}
