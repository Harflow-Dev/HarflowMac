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

    func command(_ command: String, options: [String], positionals: [String], runtime: QualificationRuntimeToken?) async throws -> [String: JSONValue] {
        if let runtime { return try await repository.command(command, options: options, positionals: positionals, runtime: runtime) }
        return try await repository.command(command, options: options, positionals: positionals)
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
    func modelOptions(backend: String) async -> [ModelOption] { await models.models(for: backend) }
}
