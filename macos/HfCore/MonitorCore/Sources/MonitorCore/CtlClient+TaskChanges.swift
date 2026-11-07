import Foundation

// MARK: - TaskChanges refusals

/// Stable refusal codes of `task-changes`.
public enum TaskChangesRefusalCode {
    public static let cursorExpired = "changes_cursor_expired"
    public static let cursorInvalid = "changes_cursor_invalid"
    public static let entryNotFound = "changes_entry_not_found"
    public static let pageTooLarge = "changes_page_too_large"
    public static let taskPendingLaunch = "task_pending_launch"
}

public extension ToolError {
    /// True for `changes_cursor_expired`: the stored document changed, so read again from the first page.
    var isTaskChangesCursorExpired: Bool { refusalCode == TaskChangesRefusalCode.cursorExpired }
}

// MARK: - CtlClient task changes

public extension CtlClient {
    /// Reads one listing page through a fresh handshake that requires `task-changes.v1`.
    func taskChangesPage(taskID: String, limit: Int = TaskChangesLimits.defaultPageLimit,
                         cursor: String? = nil) async -> Result<TaskChangesPage, ToolError> {
        guard Self.validChangesTaskID(taskID), (1 ... TaskChangesLimits.maxPageLimit).contains(limit),
              cursor.map(TaskEventPage.validCursor) ?? true else {
            return .failure(Self.changesInvalid("Invalid task-changes listing request"))
        }
        var options = ["--limit=\(limit)"]
        if let cursor { options.append("--cursor=\(cursor)") }
        return await changesDocument(options: options, taskID: taskID).flatMap { raw in
            guard let page = TaskChangesPage(raw: raw, requestedLimit: limit),
                  Self.changesIdentityMatches(page.taskID, page.resolvedFrom, requested: taskID) else {
                return .failure(Self.changesInvalid("Malformed task-changes listing or mismatched task identity"))
            }
            return .success(page)
        }
    }

    /// Reads the first chunk of one row's patch.
    func taskChangesTextChunk(taskID: String, selector: TaskChangesSelector) async -> Result<TaskChangesTextChunk, ToolError> {
        guard Self.validChangesTaskID(taskID) else { return .failure(Self.changesInvalid("Invalid task-changes text request")) }
        let options = ["--repository-root=\(selector.repositoryRoot)", "--scope=\(selector.scope.rawValue)",
                       "--path-b64=\(selector.pathBytes.base64EncodedString())"]
        return await textChunk(options: options, taskID: taskID)
    }

    /// Reads the chunk a text cursor names; the cursor stands alone, without selectors or a limit.
    func taskChangesTextChunk(taskID: String, cursor: String) async -> Result<TaskChangesTextChunk, ToolError> {
        guard Self.validChangesTaskID(taskID), TaskEventPage.validCursor(cursor) else {
            return .failure(Self.changesInvalid("Invalid task-changes text request"))
        }
        return await textChunk(options: ["--cursor=\(cursor)"], taskID: taskID)
    }

    private func textChunk(options: [String], taskID: String) async -> Result<TaskChangesTextChunk, ToolError> {
        await changesDocument(options: options, taskID: taskID).flatMap { raw in
            guard let chunk = TaskChangesTextChunk(raw: raw),
                  Self.changesIdentityMatches(chunk.taskID, chunk.resolvedFrom, requested: taskID) else {
                return .failure(Self.changesInvalid("Malformed task-changes text or mismatched task identity"))
            }
            return .success(chunk)
        }
    }

    private func changesDocument(options: [String], taskID: String) async -> Result<[String: JSONValue], ToolError> {
        let output = await raw("task-changes", options: options, positionals: [taskID], requiringCapability: CtlCapability.taskChanges)
        guard !Task.isCancelled, operationIsCurrent() else {
            return .failure(WireEnvelope.incompatibility("task-changes operation superseded"))
        }
        return output.flatMap { output in
            return CtlDocument.validatedDocument(stdout: output.stdout, stderr: output.stderr, exitCode: output.exitCode,
                                                 command: "task-changes", productVersion: compatibilityContext.productVersion)
                .flatMap { validated in
                    switch validated {
                    case .error(let code, let message): return .failure(.refused(code: code, message: message))
                    case .document(let document):
                        guard output.exitCode == 0, let result = document["result"]?.objectValue else {
                            return .failure(Self.changesInvalid("Missing task-changes result"))
                        }
                        return .success(result)
                    }
                }
        }
    }

    private static func validChangesTaskID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024 && !value.contains("\0")
    }

    private static func changesInvalid(_ detail: String) -> ToolError {
        .unreadable(tool: "harflow-ctl", exitCode: 0, stderr: detail)
    }

    private static func changesIdentityMatches(_ resultID: String, _ resolved: TaskEventResolvedFrom?, requested: String) -> Bool {
        if let resolved {
            return resolved.input == requested && resolved.taskID == resultID
                && requested.count >= 8 && resultID != requested && resultID.hasPrefix(requested)
        }
        return resultID == requested
    }
}
