import Foundation

// MARK: - WorkflowClient

public extension CtlClient {
    /// Calls the versioned workflow CLI boundary. State is owned exclusively by Polybridge.
    func workflow(_ command: String, options: [String] = [], positionals: [String] = []) async -> Result<[String: JSONValue], ToolError> {
        await result("workflow-\(command)", options: options, positionals: positionals, timeout: Self.startTimeout)
    }

    /// Validates through Polybridge without creating a saved definition or run.
    func validateWorkflow(definition: JSONValue) async -> Result<[String: JSONValue], ToolError> {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("polybridge-workflow-validation-\(UUID().uuidString).json")
        do {
            try Data(definition.rendered().utf8).write(to: input, options: .atomic)
            defer { try? FileManager.default.removeItem(at: input) }
            return await workflow("validate", options: ["--definition=\(input.path)"])
        } catch {
            return .failure(.unreadable(tool: "workflow validation input", exitCode: 0, stderr: error.localizedDescription))
        }
    }

    /// Sends an editable definition through a disposable input file; this is not a state file.
    func saveWorkflow(name: String, definition: JSONValue, expectedRevision: Int) async -> Result<[String: JSONValue], ToolError> {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("polybridge-workflow-\(UUID().uuidString).json")
        do {
            try Data(definition.rendered().utf8).write(to: input, options: .atomic)
            defer { try? FileManager.default.removeItem(at: input) }
            return await workflow("save", options: ["--definition=\(input.path)", "--expected-revision=\(expectedRevision)"], positionals: [name])
        } catch {
            return .failure(.unreadable(tool: "workflow input", exitCode: 0, stderr: error.localizedDescription))
        }
    }
}
