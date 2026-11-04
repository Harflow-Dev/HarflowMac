import MonitorCore

// MARK: - PublicEventObservationReader

protocol PublicEventObservationReader: Sendable {
    func read(taskID: String, position: TaskEventPagePosition,
              operationIsCurrent: @escaping @Sendable () -> Bool) async -> Result<TaskEventPage, ToolError>
}

/// Captures a client once per operation, retaining its fence and exact selected binding.
struct BoundPublicEventObservationReader: PublicEventObservationReader {
    let tooling: any ToolEnvironmentRepository

    func read(taskID: String, position: TaskEventPagePosition,
              operationIsCurrent: @escaping @Sendable () -> Bool) async -> Result<TaskEventPage, ToolError> {
        guard operationIsCurrent(), !Task.isCancelled else { return .failure(Self.superseded) }
        let captured: CtlClient
        switch tooling.ctl() {
        case .success(let client): captured = client
        case .failure(let error): return .failure(error)
        }
        let tooling = tooling
        let current: @Sendable () -> Bool = {
            guard operationIsCurrent(), !Task.isCancelled, captured.operationIsCurrent(),
                  case .success(let fresh) = tooling.ctl() else { return false }
            return fresh.executable == captured.executable && fresh.environment == captured.environment
                && fresh.compatibilityContext == captured.compatibilityContext
        }
        var client = captured
        client.operationIsCurrent = current
        guard current() else { return .failure(Self.superseded) }
        let result = await client.taskEvents(taskID: taskID, position: position, limit: 100, selection: .all)
        guard current() else { return .failure(Self.superseded) }
        return result
    }

    private static var superseded: ToolError {
        .unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Event observation superseded")
    }
}
