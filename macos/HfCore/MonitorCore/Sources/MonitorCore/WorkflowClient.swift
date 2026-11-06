import Foundation

// MARK: - WorkflowClient

public extension CtlClient {
    /// Advisory shared-channel availability. The engine rechecks the exact checkpoint at submission.
    func supportsSharedWorkflowInteractions() async -> Result<Bool, ToolError> {
        await VersionInfoClient(executable: executable, environment: environment, context: compatibilityContext, runner: runner)
            .check().map { $0.capabilities.contains(CtlCapability.workflowSharedInteractions) }
    }

    /// Calls the versioned workflow CLI boundary. State is owned exclusively by Harflow.
    func workflow(_ command: String, options: [String] = [], positionals: [String] = []) async -> Result<[String: JSONValue], ToolError> {
        // Preserve the existing settled-only generic API. Native live observation uses
        // the dedicated intent-bearing method below.
        if Self.isWorkflowActivity("workflow-\(command)", options: options) {
            return await result("workflow-inspect", options: options, positionals: positionals).flatMap { payload in
                guard payload["settled"] != .bool(false) else {
                    return .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Unsettled workflow activity response"))
                }
                return .success(payload)
            }
        }
        let hasDecision = options.contains { $0 == "--decision-id" || $0.hasPrefix("--decision-id=") }
        if command == "recover", hasDecision {
            return .failure(.refused(code: "attention_checkpoint_invalid",
                                     message: "Recovery does not accept a question decision ID. Use resume to answer a question."))
        }
        let guarded = ["resume", "recover"].contains(command) && options.contains("--monitor")
            && !(command == "resume" && hasDecision)
        let checkpoint = options.first { $0.hasPrefix("--attention-checkpoint-id=") }
        if checkpoint != nil, hasDecision {
            return .failure(.refused(code: "attention_checkpoint_invalid", message: "A decision and an attention checkpoint cannot be submitted together."))
        }
        if guarded && (checkpoint == nil || checkpoint == "--attention-checkpoint-id=") {
            return .failure(.refused(code: "attention_checkpoint_unavailable",
                                     message: "This engine cannot identify the displayed checkpoint. Refresh the workflow before continuing."))
        }
        let capability: String? = checkpoint != nil || guarded ? CtlCapability.workflowAttentionCheckpoints
            : (["send", "cancel-message"].contains(command) || command == "build" && options.contains("--monitor") ? "messaging.v1" : nil)
        return await result("workflow-\(command)", options: options, positionals: positionals, timeout: Self.startTimeout,
                            requiringCapability: capability)
    }

    /// Reads a bounded activity page. Intent is native admission evidence, never a new wire flag.
    func workflowActivity(runID: String, executionID: String, intent: WorkflowActivityReadIntent) async -> Result<WorkflowActivityPage, ToolError> {
        await result("workflow-inspect", options: ["--view=activity", "--limit=200"], positionals: [runID, executionID],
                     requiringCapability: intent == .allowUnsettled ? CtlCapability.workflowLiveActivity : nil).flatMap { raw in
            guard let page = WorkflowActivityPage(raw: raw, runID: runID, executionID: executionID),
                  intent != .settledOnly || page.settled != false else {
                return .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Invalid or unsettled workflow activity response"))
            }
            return .success(page)
        }
    }

    /// Validates through Harflow without creating a saved definition or run.
    func validateWorkflow(definition: JSONValue) async -> Result<[String: JSONValue], ToolError> {
        do {
            let input = try WorkflowDefinitionInput(definition: definition)
            defer { input.cleanUp() }
            return await workflow("validate", options: ["--definition=\(input.file.path)"])
        } catch {
            return .failure(.unreadable(tool: "workflow validation input", exitCode: 0, stderr: error.localizedDescription))
        }
    }

    /// Sends an editable definition through a disposable input file; this is not a state file.
    func saveWorkflow(
        name: String, definition: JSONValue, expectedRevision: Int, expectedWorkflowID: String? = nil
    ) async -> Result<[String: JSONValue], ToolError> {
        do {
            let input = try WorkflowDefinitionInput(definition: definition)
            defer { input.cleanUp() }
            let identity = expectedWorkflowID.map { ["--expected-workflow-id=\($0)"] } ?? []
            return await workflow("save", options: ["--definition=\(input.file.path)", "--expected-revision=\(expectedRevision)"] + identity,
                                  positionals: [name])
        } catch {
            return .failure(.unreadable(tool: "workflow input", exitCode: 0, stderr: error.localizedDescription))
        }
    }
}

// MARK: - WorkflowDefinitionInput

/// Keeps definition payloads private for their entire temporary lifetime.
struct WorkflowDefinitionInput {
    let file: URL
    private let directory: URL

    init(definition: JSONValue) throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("harflow-workflow-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("definition.json")
        do {
            try Data(definition.rendered().utf8).write(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
        self.directory = directory
        self.file = file
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}
