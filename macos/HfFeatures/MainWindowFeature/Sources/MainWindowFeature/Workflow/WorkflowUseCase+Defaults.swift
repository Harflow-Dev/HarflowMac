import Combine
import HfRepository
import MonitorCore

// MARK: - WorkflowUseCase defaults

extension WorkflowUseCase {
    func steeringObservation(rootID _: String) async throws -> WorkflowSteeringObservation { throw WorkflowSteeringAdmissionError.unsupported }
    func steeringHistory(observation _: WorkflowSteeringObservation, cursor _: String?) async throws -> WorkflowSteeringHistoryPage {
        throw WorkflowSteeringAdmissionError.unsupported
    }

    func performSteering(action _: WorkflowSteeringAction, text _: String?,
                         observation _: WorkflowSteeringObservation) async throws -> WorkflowSteeringAttempt {
        throw WorkflowSteeringAdmissionError.unsupported
    }

    func steeringAttempts(rootID _: String) -> [WorkflowSteeringAttempt] { [] }
    func isSteeringCurrent(_: WorkflowSteeringObservation) -> Bool { false }

    func activityRuntime() throws -> QualificationRuntimeToken {
        throw ToolError.notFound(tool: "harflow-ctl", searched: [])
    }

    func activity(runID _: String, executionID _: String, intent _: WorkflowActivityReadIntent,
                  runtime _: QualificationRuntimeToken) async throws -> WorkflowActivityPage {
        throw ToolError.unsupportedCommand(tool: "harflow-ctl", command: "workflow-inspect", detail: "Runtime-bound activity unavailable")
    }

    func command(_ command: String, options: [String], positionals: [String]) async throws -> [String: JSONValue] {
        try await self.command(command, options: options, positionals: positionals, runtime: nil)
    }

    func boundBuilderCommand(_ command: String, options: [String], positionals: [String], runtime: QualificationRuntimeToken,
                             isCurrent: @escaping @Sendable () -> Bool) async throws -> [String: JSONValue] {
        guard isCurrent() else { throw CancellationError() }
        return try await self.command(command, options: options, positionals: positionals, runtime: runtime)
    }

    func qualificationSession() -> QualificationSession { QualificationSession(repository: NullQualificationRepository()) }
    var agentUsageSnapshot: AgentUsageSnapshot { .init() }
    func agentUsagePublisher() -> AnyPublisher<AgentUsageSnapshot, Never> { Just(.init()).eraseToAnyPublisher() }
    func recordAgentUsage(_: AgentUsageIdentity, acknowledgementID _: String) async {}
    var callerApprovalBackends: Set<String> { [] }
    func artifactPage(runID _: String, executionID _: String, cursor _: String?) async -> Result<WorkflowArtifactPage, ToolError> {
        .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Artifact metadata unavailable"))
    }
}

// MARK: - WorkflowRouting preview defaults

extension WorkflowRouting {
    func showNeedsYou(itemID _: String?) {}
}
