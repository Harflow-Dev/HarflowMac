import Combine
import HfRepository
import MonitorCore

// MARK: - WorkflowUseCase defaults

extension WorkflowUseCase {
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
