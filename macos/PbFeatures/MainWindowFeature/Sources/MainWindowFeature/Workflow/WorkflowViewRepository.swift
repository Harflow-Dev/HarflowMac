import Foundation
import MonitorCore
import PbRepository
import SwiftEnvironment

// MARK: - WorkflowViewRepository

@MainActor
final class WorkflowViewRepository: WorkflowUseCase, @unchecked Sendable {
    @GlobalEnvironment(\.workflowArtifactRepository) private var artifacts
    @GlobalEnvironment(\.workflowRepository) private var repository
    @GlobalEnvironment(\.taskListRepository) private var taskList
    @GlobalEnvironment(\.backendsRepository) private var backends
    @GlobalEnvironment(\.modelCatalogRepository) private var models

    func command(_ command: String, options: [String], positionals: [String]) async throws -> [String: JSONValue] {
        try await repository.command(command, options: options, positionals: positionals)
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
    var backendIDs: [String] { backends.catalog.entries.map(\.backend) }
    func modelOptions(backend: String) async -> [ModelOption] { await models.models(for: backend) }
}
