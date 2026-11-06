import Foundation
import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - WorkflowRepository

/// CLI-only workflow persistence and execution seam. No Monitor code writes workflow state.
@Mockable
public protocol WorkflowRepository: Sendable {
    /// Reads activity with explicit settlement admission, bound to one current selected runtime.
    func activityRuntime() throws -> QualificationRuntimeToken
    func activity(runID: String, executionID: String, intent: WorkflowActivityReadIntent,
                  runtime: QualificationRuntimeToken) async throws -> WorkflowActivityPage
    func historyBatch(runIDs: [String]) async throws -> HistoryPage
    func historyPage(cursor: String?, activeOnly: Bool, relatedRunID: String?) async throws -> HistoryPage
    /// Executes a workflow command and returns its versioned result payload.
    func command(_ command: String, options: [String], positionals: [String]) async throws -> [String: JSONValue]
    /// Binds this operation to the runtime that produced its qualification evidence.
    func command(_ command: String, options: [String], positionals: [String], runtime: QualificationRuntimeToken) async throws -> [String: JSONValue]
    /// Validates an editable graph without saving workflow state.
    func validate(definition: JSONValue) async throws -> [String: JSONValue]
    /// Saves against the revision the editor loaded, refusing concurrent edits.
    func save(name: String, definition: JSONValue, expectedRevision: Int, expectedWorkflowID: String?) async throws -> [String: JSONValue]
}

// MARK: - WorkflowRepositoryImpl

/// Resolves the configured CLI for every operation, including settings changes.
public struct WorkflowRepositoryImpl: WorkflowRepository {
    private let toolEnvironment: any ToolEnvironmentRepository
    private let stateRecovery: any StateRecoveryRepository

    /// Creates a workflow repository with the Monitor's shared tool discovery.
    public init(toolEnvironment: any ToolEnvironmentRepository, stateRecovery: (any StateRecoveryRepository)? = nil) {
        self.toolEnvironment = toolEnvironment
        self.stateRecovery = stateRecovery ?? NullStateRecoveryRepository()
    }

    public func activityRuntime() throws -> QualificationRuntimeToken {
        try QualificationRuntimeToken(client: toolEnvironment.ctl().get())
    }

    public func activity(runID: String, executionID: String, intent: WorkflowActivityReadIntent,
                         runtime: QualificationRuntimeToken) async throws -> WorkflowActivityPage {
        let client = try runtime.boundClient(tooling: toolEnvironment)
        let result = await client.workflowActivity(runID: runID, executionID: executionID, intent: intent)
        guard client.operationIsCurrent(), !Task.isCancelled else { throw QualificationSessionError.runtimeChanged }
        return try observed(result)
    }

    public func historyBatch(runIDs: [String]) async throws -> HistoryPage {
        let ctl = try toolEnvironment.ctl().get()
        return try observed(await ctl.workflowHistoryPage(runIDs: runIDs))
    }

    public func historyPage(cursor: String? = nil, activeOnly: Bool = false, relatedRunID: String? = nil) async throws -> HistoryPage {
        let ctl = try toolEnvironment.ctl().get()
        return try observed(await ctl.workflowHistoryPage(cursor: cursor, activeOnly: activeOnly, relatedRunID: relatedRunID))
    }

    public func command(_ command: String, options: [String], positionals: [String]) async throws -> [String: JSONValue] {
        try await self.command(command, options: options, positionals: positionals, using: toolEnvironment.ctl().get())
    }

    /// Binds this operation to the runtime that produced its qualification evidence.
    public func command(_ command: String, options: [String], positionals: [String], runtime: QualificationRuntimeToken) async throws -> [String: JSONValue] {
        try await self.command(command, options: options, positionals: positionals, using: runtime.boundClient(tooling: toolEnvironment))
    }

    private func command(_ command: String, options: [String], positionals: [String], using ctl: CtlClient) async throws -> [String: JSONValue] {
        // Workflow prompts, control instructions and builder JSON are logical payloads, never argv entries.
        // Keep its disposable files alive until the CLI has finished, including failures.
        let payloadCommands = ["build", "start", "builder-followup", "resume", "recover", "revise-goal"]
        let input = payloadCommands.contains(command) ? try WorkflowCommandInputs.prepare(options: options) : nil
        defer { input?.cleanUp() }
        var processOptions = input?.options ?? options
        if command == "list", !processOptions.contains("--monitor-view") {
            processOptions.append("--monitor-view")
        }
        return try observed(await ctl.workflow(command, options: processOptions, positionals: positionals))
    }

    public func validate(definition: JSONValue) async throws -> [String: JSONValue] {
        let ctl = try toolEnvironment.ctl().get()
        return try observed(await ctl.validateWorkflow(definition: definition))
    }

    public func save(name: String, definition: JSONValue, expectedRevision: Int, expectedWorkflowID: String?) async throws -> [String: JSONValue] {
        let ctl = try toolEnvironment.ctl().get()
        return try observed(await ctl.saveWorkflow(
            name: name, definition: definition, expectedRevision: expectedRevision, expectedWorkflowID: expectedWorkflowID
        ))
    }

    private func observed<Value>(_ result: Result<Value, ToolError>) throws -> Value {
        if case .failure(let error) = result { stateRecovery.report(error) }
        return try result.get()
    }
}

public extension WorkflowRepository {
    func activityRuntime() throws -> QualificationRuntimeToken {
        throw ToolError.notFound(tool: "harflow-ctl", searched: [])
    }

    func activity(runID _: String, executionID _: String, intent _: WorkflowActivityReadIntent,
                  runtime _: QualificationRuntimeToken) async throws -> WorkflowActivityPage {
        throw ToolError.unsupportedCommand(tool: "harflow-ctl", command: "workflow-inspect", detail: "Runtime-bound activity unavailable")
    }

    func historyBatch(runIDs: [String]) async throws -> HistoryPage {
        throw ToolError.unsupportedCommand(tool: "harflow-ctl", command: "workflow-list-page", detail: "History batches unavailable")
    }

    func historyPage(cursor: String? = nil, activeOnly: Bool = false, relatedRunID: String? = nil) async throws -> HistoryPage {
        throw ToolError.unsupportedCommand(tool: "harflow-ctl", command: "workflow-list-page", detail: "History pages unavailable")
    }
}

// MARK: - NullWorkflowRepository

/// Safe pre-registration default that performs no work.
public struct NullWorkflowRepository: WorkflowRepository {
    public init() {}
    public func command(_: String, options _: [String], positionals _: [String]) async throws -> [String: JSONValue] {
        throw ToolError.notFound(tool: "harflow-ctl", searched: [])
    }

    public func validate(definition _: JSONValue) async throws -> [String: JSONValue] {
        throw ToolError.notFound(tool: "harflow-ctl", searched: [])
    }

    public func save(name _: String, definition _: JSONValue, expectedRevision _: Int, expectedWorkflowID _: String?) async throws -> [String: JSONValue] {
        throw ToolError.notFound(tool: "harflow-ctl", searched: [])
    }
}

public extension GlobalValues {
    /// Shared workflow CLI repository.
    @GlobalEntry var workflowRepository: any WorkflowRepository = NullWorkflowRepository()
}

public extension WorkflowRepository {
    func command(_: String, options _: [String], positionals _: [String], runtime _: QualificationRuntimeToken) async throws -> [String: JSONValue] {
        throw ToolError.unsupportedCommand(tool: "harflow-ctl", command: "workflow", detail: "Runtime-bound command unavailable")
    }
}
