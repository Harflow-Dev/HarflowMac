import Combine
import Foundation
import HfRepository
import MonitorCore
import SwiftEnvironment

// MARK: - WorkflowViewRepository

@MainActor
final class WorkflowViewRepository: WorkflowUseCase, @unchecked Sendable {
    @GlobalEnvironment(\.qualificationRepository) private var qualificationRepository
    func qualificationSession() -> QualificationSession { QualificationSession(repository: qualificationRepository) }

    @GlobalEnvironment(\.workflowArtifactRepository) private var artifacts
    @GlobalEnvironment(\.workflowRepository) private var repository
    @GlobalEnvironment(\.taskListRepository) private var taskList
    @GlobalEnvironment(\.backendsRepository) private var backends
    @GlobalEnvironment(\.modelCatalogRepository) private var models
    @GlobalEnvironment(\.agentUsageRepository) private var usage
    @GlobalEnvironment(\.taskActionRepository) private var taskActions
    @GlobalEnvironment(\.toolEnvironmentRepository) private var toolEnvironment

    func command(_ command: String, options: [String], positionals: [String], runtime: QualificationRuntimeToken?) async throws -> [String: JSONValue] {
        if let runtime { return try await repository.command(command, options: options, positionals: positionals, runtime: runtime) }
        return try await repository.command(command, options: options, positionals: positionals)
    }

    func boundBuilderCommand(_ command: String, options: [String], positionals: [String], runtime: QualificationRuntimeToken,
                             isCurrent: @escaping @Sendable () -> Bool) async throws -> [String: JSONValue] {
        try await repository.command(command, options: options, positionals: positionals, runtime: runtime, isCurrent: isCurrent)
    }

    func activityRuntime() throws -> QualificationRuntimeToken { try repository.activityRuntime() }

    func activity(runID: String, executionID: String, intent: WorkflowActivityReadIntent,
                  runtime: QualificationRuntimeToken) async throws -> WorkflowActivityPage {
        try await repository.activity(runID: runID, executionID: executionID, intent: intent, runtime: runtime)
    }

    func validate(definition: JSONValue) async throws -> [String: JSONValue] {
        try await repository.validate(definition: definition)
    }

    func save(name: String, definition: JSONValue, expectedRevision: Int, expectedWorkflowID: String?) async throws -> [String: JSONValue] {
        try await repository.save(name: name, definition: definition, expectedRevision: expectedRevision, expectedWorkflowID: expectedWorkflowID)
    }

    func artifactPage(runID: String, executionID: String, cursor: String?) async -> Result<WorkflowArtifactPage, ToolError> {
        await artifacts.page(runID: runID, executionID: executionID, cursor: cursor)
    }

    func refreshTasks() async { await taskList.refresh() }
    var callerApprovalBackends: Set<String> {
        backends.catalog.state == .available
            ? Set(backends.catalog.entries.filter(\.supportsCallerApprovals).map(\.backend)) : []
    }

    var agentUsageSnapshot: AgentUsageSnapshot { usage.snapshot }
    func agentUsagePublisher() -> AnyPublisher<AgentUsageSnapshot, Never> { usage.snapshotPublisher() }
    func recordAgentUsage(_ identity: AgentUsageIdentity, acknowledgementID: String) async {
        await usage.record(identity, acknowledgementID: acknowledgementID)
    }

    var backendIDs: [String] { backends.catalog.entries.map(\.backend) }
    var backendCatalog: BackendCatalog { backends.catalog }
    func backendCatalogPublisher() -> AnyPublisher<BackendCatalog, Never> { backends.catalogPublisher() }
    func modelOptions(backend: String) async -> [ModelOption] { await models.models(for: backend) }
}

// MARK: - WorkflowMessagingSupport

extension WorkflowViewRepository: WorkflowMessagingSupport {
    func messagingInvocationContext() throws -> MessagingInvocationContext { try taskActions.messagingInvocationContext() }

    func isMessagingContextCurrent(_ context: MessagingInvocationContext) -> Bool { taskActions.isMessagingContextCurrent(context) }

    func messagingSupport(context: MessagingInvocationContext) async -> Bool? {
        guard isMessagingContextCurrent(context), let client = try? toolEnvironment.ctl().get(),
              QualificationRuntimeToken(client: client) == context.runtime else { return nil }
        let result = await VersionInfoClient(executable: client.executable, environment: client.environment,
                                           context: client.compatibilityContext, runner: client.runner).check()
        guard isMessagingContextCurrent(context), client.operationIsCurrent(), !Task.isCancelled,
              case .success(let info) = result else { return nil }
        return info.capabilities.contains("messaging.v1")
    }
}
