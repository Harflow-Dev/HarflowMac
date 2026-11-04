import Foundation

// MARK: - TaskPromptResult

/// A bounded prompt read retaining integrity, completeness and additive wire facts.
public struct TaskPromptResult: Equatable, Sendable {
    /// Engine-reported availability; completeness and integrity remain independent.
    public enum State: String, Equatable, Sendable {
        case available, previewOnly = "preview_only", integrityFailed = "integrity_failed", unavailable
    }

    /// Verification performed by the engine, independently of completeness.
    public enum Integrity: String, Equatable, Sendable {
        case verified, failed, unverified, notApplicable = "not_applicable"
    }

    /// Explicit provenance for a prefix resolved by the engine.
    public struct ResolvedFrom: Equatable, Sendable {
        public let input: String
        public let taskID: String
        public let raw: [String: JSONValue]

        fileprivate init?(raw: [String: JSONValue]) {
            guard let input = raw["input"]?.stringValue, !input.isEmpty,
                  let taskID = raw["task_id"]?.stringValue, !taskID.isEmpty else { return nil }
            self.input = input
            self.taskID = taskID
            self.raw = raw
        }
    }

    public let taskID: String
    public let title: String
    public let state: State
    public let text: String?
    public let returnedBytes: Int
    public let totalBytes: Int?
    public let truncated: Bool
    public let complete: Bool
    public let integrity: Integrity
    public let resolvedFrom: ResolvedFrom?
    /// Original result, including unknown additive fields at every nesting level.
    public let raw: [String: JSONValue]

    /// Decodes exact known wire types and bounds text by its UTF-8 size.
    public init?(raw: [String: JSONValue], maxBytes: Int = 65536) {
        guard (1 ... 131072).contains(maxBytes),
              let taskID = raw["task_id"]?.stringValue, !taskID.isEmpty,
              let title = raw["title"]?.stringValue,
              let prompt = raw["prompt"]?.objectValue,
              let stateName = prompt["state"]?.stringValue, let state = State(rawValue: stateName),
              let integrityName = prompt["integrity"]?.stringValue, let integrity = Integrity(rawValue: integrityName),
              let returned = prompt["returned_bytes"]?.wireIntegerValue, (0 ... maxBytes).contains(returned),
              let truncated = prompt["truncated"]?.boolValue,
              let complete = prompt["complete"]?.boolValue,
              prompt["text"] == .null || prompt["text"]?.stringValue != nil,
              prompt["total_bytes"] == .null || prompt["total_bytes"]?.wireIntegerValue != nil else { return nil }
        let text = prompt["text"]?.stringValue
        let total = prompt["total_bytes"]?.wireIntegerValue
        guard total.map({ $0 >= 0 }) ?? true, (text?.utf8.count ?? 0) == returned,
              !complete || (!truncated && (total == nil || total == returned)) else { return nil }
        switch state {
        case .available:
            guard text != nil, integrity != .failed else { return nil }
        case .previewOnly:
            guard text != nil, !complete, integrity == .notApplicable, total == nil else { return nil }
        case .integrityFailed:
            guard text == nil, !complete, !truncated, integrity == .failed, total == nil else { return nil }
        case .unavailable:
            guard text == nil, !complete, !truncated, integrity == .notApplicable, total == nil else { return nil }
        }
        var resolution: ResolvedFrom?
        if let value = raw["resolved_from"] {
            guard let object = value.objectValue, let decoded = ResolvedFrom(raw: object) else { return nil }
            resolution = decoded
        }
        self.taskID = taskID
        self.title = title
        self.state = state
        self.text = text
        returnedBytes = returned
        totalBytes = total
        self.truncated = truncated
        self.complete = complete
        self.integrity = integrity
        resolvedFrom = resolution
        self.raw = raw
    }
}

// MARK: - CtlClient task prompt

public extension CtlClient {
    /// Reads one prompt through a fresh capability handshake without accessing private storage.
    func taskPrompt(taskID: String, maxBytes: Int = 65536) async -> Result<TaskPromptResult, ToolError> {
        guard (1 ... 131072).contains(maxBytes) else {
            return .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "task-prompt maxBytes must be 1...131072"))
        }
        let response = await result("task-prompt", options: ["--max-bytes=\(maxBytes)"],
                                    positionals: [taskID], requiringCapability: CtlCapability.taskPrompt)
        guard !Task.isCancelled, operationIsCurrent() else {
            return .failure(WireEnvelope.incompatibility("task-prompt operation superseded"))
        }
        return response.flatMap { raw in
            guard let prompt = TaskPromptResult(raw: raw, maxBytes: maxBytes),
                  Self.promptIdentityMatches(prompt, requested: taskID) else {
                return .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Malformed task-prompt result or mismatched task identity"))
            }
            return .success(prompt)
        }
    }

    private static func promptIdentityMatches(_ prompt: TaskPromptResult, requested: String) -> Bool {
        if let resolved = prompt.resolvedFrom {
            return resolved.input == requested && resolved.taskID == prompt.taskID
                && requested.count >= 8 && prompt.taskID != requested && prompt.taskID.hasPrefix(requested)
        }
        return prompt.taskID == requested
    }
}
