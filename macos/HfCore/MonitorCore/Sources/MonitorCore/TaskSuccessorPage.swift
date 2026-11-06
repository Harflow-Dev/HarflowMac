import Foundation

// MARK: - TaskSuccessorPage

/// A bounded observation of recorded direct successors, excluding pending launches.
public struct TaskSuccessorPage: Equatable, Sendable {
    public let predecessorTaskID: String
    public let history: TaskHistoryPage
    /// Missing readiness metadata cannot establish a complete recorded observation.
    public let readinessUnknown: Bool

    public init?(raw: [String: JSONValue], predecessorTaskID: String) {
        guard !predecessorTaskID.isEmpty, predecessorTaskID.utf8.count <= 1024,
              raw["successor_scope"]?.stringValue == "recorded_tasks",
              raw["predecessor_task_id"]?.stringValue == predecessorTaskID,
              JSONValue.object(raw).rendered().utf8.count <= 256 * 1024 else { return nil }
        guard Self.validMetadata(raw) else { return nil }
        guard let history = TaskHistoryPage(raw: raw),
              history.page.nextCursor.map({ !$0.isEmpty && $0.utf8.count <= 2048 }) ?? true,
              history.items.allSatisfy({ $0.parentTaskID == predecessorTaskID || $0.raw["continuation_of_task_id"]?.stringValue == predecessorTaskID }),
              Set(history.items.map(\.taskID)).count == history.items.count else { return nil }
        guard history.page.items.reduce(0, { $0 + Self.wireBytes($1) }) <= 128 * 1024 else { return nil }
        for row in history.page.items + history.page.relatedHeaders {
            guard let id = row["task_id"]?.stringValue, !id.isEmpty, id.utf8.count <= 1024,
                  Self.wireBytes(row) <= 128 * 1024 else { return nil }
        }
        readinessUnknown = raw["catalog_state"] == nil
        self.predecessorTaskID = predecessorTaskID
        self.history = history
    }
    private static func validMetadata(_ raw: [String: JSONValue]) -> Bool {
        for key in ["has_more", "bootstrap_pending", "history_incomplete", "authority_incomplete", "counts_complete"] {
            if let value = raw[key], value.boolValue == nil { return false }
        }
        for key in ["total_active_count", "total_active_root_count", "total_attention_root_count"] {
            if let value = raw[key], value != .null {
                guard let count = value.wireIntegerValue, count >= 0 else { return false }
            }
        }
        if let related = raw["related_headers"], related.arrayValue == nil { return false }
        return validCatalog(raw["catalog_state"])
    }

    private static func validCatalog(_ catalog: JSONValue?) -> Bool {
        guard let catalog else { return true }
        guard let state = catalog.objectValue,
              let status = state["status"]?.stringValue, CatalogState.Status(rawValue: status) != nil,
              let source = state["source"]?.stringValue, !source.isEmpty else { return false }
        for key in ["pending_records", "blocked_records"] {
            guard let count = state[key]?.wireIntegerValue, count >= 0 else { return false }
        }
        if let reason = state["reason"], reason != .null, reason.stringValue == nil { return false }
        return true
    }

    private static func wireBytes(_ row: [String: JSONValue]) -> Int {
        JSONValue.object(row).rendered().unicodeScalars.reduce(0) { total, scalar in
            total + (scalar.value < 127 ? 1 : scalar.value > 0xFFFF ? 12 : 6)
        }
    }
}

public extension CtlClient {
    /// Reads only recorded direct successors with a fresh capability handshake per page.
    func taskSuccessorPage(predecessorTaskID: String, cursor: String? = nil, limit: Int = 100) async -> Result<TaskSuccessorPage, ToolError> {
        guard !predecessorTaskID.isEmpty, predecessorTaskID.utf8.count <= 1024,
              cursor.map({ !$0.isEmpty && $0.utf8.count <= 2048 }) ?? true else {
            return .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Invalid successor selector"))
        }
        var options = ["--predecessor-task-id=\(predecessorTaskID)", "--limit=\(min(100, max(1, limit)))"]
        if let cursor { options.append("--cursor=\(cursor)") }
        let output = await raw("task-list-page", options: options, requiringCapability: CtlCapability.taskSuccessors)
        let response: Result<[String: JSONValue], ToolError> = output.flatMap { output in
            guard output.stdout.count <= 256 * 1024 else {
                return .failure(.unreadable(tool: "harflow-ctl", exitCode: output.exitCode, stderr: "Recorded successor document exceeds bound"))
            }
            return CtlDocument.validatedDocument(stdout: output.stdout, stderr: output.stderr, exitCode: output.exitCode,
                                                 command: "task-list-page", productVersion: compatibilityContext.productVersion).flatMap { validated in
                switch validated {
                case .error(let code, let message): return .failure(.refused(code: code, message: message))
                case .document(let document):
                    guard output.exitCode == 0, let result = document["result"]?.objectValue else {
                        return .failure(.unreadable(tool: "harflow-ctl", exitCode: output.exitCode, stderr: "Missing recorded successor result"))
                    }
                    return .success(result)
                }
            }
        }
        guard operationIsCurrent(), !Task.isCancelled else {
            return .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Successor observation superseded"))
        }
        return response.flatMap { raw in
            guard let page = TaskSuccessorPage(raw: raw, predecessorTaskID: predecessorTaskID) else {
                return .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Malformed recorded successor page"))
            }
            return .success(page)
        }
    }
}
