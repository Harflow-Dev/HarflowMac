import Foundation
import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - WorkflowRepository

/// CLI-only workflow persistence and execution seam. No Monitor code writes workflow state.
@Mockable
public protocol WorkflowRepository: Sendable {
    /// Executes a workflow command and returns its versioned result payload.
    func command(_ command: String, options: [String], positionals: [String]) async throws -> [String: JSONValue]
    /// Validates an editable graph without saving workflow state.
    func validate(definition: JSONValue) async throws -> [String: JSONValue]
    /// Saves against the revision the editor loaded, refusing concurrent edits.
    func save(name: String, definition: JSONValue, expectedRevision: Int) async throws -> [String: JSONValue]
}

// MARK: - WorkflowRepositoryImpl

/// Resolves the configured CLI for every operation, including settings changes.
public struct WorkflowRepositoryImpl: WorkflowRepository {
    private let toolEnvironment: any ToolEnvironmentRepository

    /// Creates a workflow repository with the Monitor's shared tool discovery.
    public init(toolEnvironment: any ToolEnvironmentRepository) {
        self.toolEnvironment = toolEnvironment
    }

    public func command(_ command: String, options: [String], positionals: [String]) async throws -> [String: JSONValue] {
        let ctl = try toolEnvironment.ctl().get()
        return try await ctl.workflow(command, options: options, positionals: positionals).get()
    }

    public func validate(definition: JSONValue) async throws -> [String: JSONValue] {
        let ctl = try toolEnvironment.ctl().get()
        return try await ctl.validateWorkflow(definition: definition).get()
    }

    public func save(name: String, definition: JSONValue, expectedRevision: Int) async throws -> [String: JSONValue] {
        let ctl = try toolEnvironment.ctl().get()
        return try await ctl.saveWorkflow(name: name, definition: definition, expectedRevision: expectedRevision).get()
    }
}

// MARK: - NullWorkflowRepository

/// Safe pre-registration default that performs no work.
public struct NullWorkflowRepository: WorkflowRepository {
    public init() {}
    public func command(_: String, options _: [String], positionals _: [String]) async throws -> [String: JSONValue] {
        throw ToolError.notFound(tool: "polybridge-ctl", searched: [])
    }

    public func validate(definition _: JSONValue) async throws -> [String: JSONValue] {
        throw ToolError.notFound(tool: "polybridge-ctl", searched: [])
    }

    public func save(name _: String, definition _: JSONValue, expectedRevision _: Int) async throws -> [String: JSONValue] {
        throw ToolError.notFound(tool: "polybridge-ctl", searched: [])
    }
}

public extension GlobalValues {
    /// Shared workflow CLI repository.
    @GlobalEntry var workflowRepository: any WorkflowRepository = NullWorkflowRepository()
}
