import Foundation

// MARK: - WorkflowClient

public extension CtlClient {
    /// Calls the versioned workflow CLI boundary. State is owned exclusively by Polybridge.
    func workflow(_ command: String, options: [String] = [], positionals: [String] = []) async -> Result<[String: JSONValue], ToolError> {
        await result("workflow-\(command)", options: options, positionals: positionals, timeout: Self.startTimeout)
    }

    /// Validates through Polybridge without creating a saved definition or run.
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
    func saveWorkflow(name: String, definition: JSONValue, expectedRevision: Int) async -> Result<[String: JSONValue], ToolError> {
        do {
            let input = try WorkflowDefinitionInput(definition: definition)
            defer { input.cleanUp() }
            return await workflow("save", options: ["--definition=\(input.file.path)", "--expected-revision=\(expectedRevision)"], positionals: [name])
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
        let directory = manager.temporaryDirectory.appendingPathComponent("polybridge-workflow-\(UUID().uuidString)", isDirectory: true)
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
