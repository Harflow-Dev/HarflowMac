import Foundation

// MARK: - WorkflowArtifactBinding

/// Immutable workflow ownership recorded when a reference was registered.
public struct WorkflowArtifactBinding: Equatable, Sendable {
    public let rootRunID: String
    public let runID: String
    public let executionID: String
    public let nodeID: String
    public let taskID: String
    public let role: String
    public let attribution: String
    public let hostedNativeAttemptIDs: [String]
    public let visitID: String?
    public let attemptInVisit: Int?
    public let retryOfExecutionID: String?

    public init?(raw: [String: JSONValue], taskID: String) {
        guard let root = raw["root_workflow_run_id"]?.stringValue, !root.isEmpty,
              let run = raw["workflow_run_id"]?.stringValue, !run.isEmpty,
              let execution = raw["execution_id"]?.stringValue, !execution.isEmpty,
              let node = raw["node_id"]?.stringValue,
              raw["task_id"]?.stringValue == taskID,
              let role = raw["role"]?.stringValue, ["node", "orchestrator", "native_control"].contains(role),
              let attribution = raw["attribution"]?.stringValue,
              attribution == (role == "native_control" ? "native_transport" : "attempt"),
              raw["provenance"]?.stringValue == "workflow_receipt" else { return nil }
        let hosted = raw["hosted_native_attempt_ids"]?.arrayValue ?? []
        guard hosted.count <= 32, hosted.allSatisfy({ $0.stringValue != nil }) else { return nil }
        rootRunID = root
        runID = run
        executionID = execution
        nodeID = node
        self.taskID = taskID
        self.role = role
        self.attribution = attribution
        hostedNativeAttemptIDs = hosted.compactMap(\.stringValue)
        visitID = raw["visit_id"]?.stringValue
        attemptInVisit = raw["attempt_in_visit"]?.intValue
        retryOfExecutionID = raw["retry_of_execution_id"]?.stringValue
    }
}

// MARK: - WorkflowArtifactOwner

/// An owner whose references could not be read on this page.
public struct WorkflowArtifactOwner: Equatable, Sendable {
    public let taskID: String?
    public let runID: String
    public let executionID: String?
    public let state: String

    public init?(raw: [String: JSONValue]) {
        guard let run = raw["workflow_run_id"]?.stringValue,
              let state = raw["state"]?.stringValue,
              ["unavailable", "record_removed", "run_unavailable"].contains(state) else { return nil }
        runID = run
        taskID = raw["task_id"]?.stringValue
        executionID = raw["execution_id"]?.stringValue
        self.state = state
    }
}

// MARK: - WorkflowArtifactPage

/// Bounded workflow-tree metadata page; no file content is loaded.
public struct WorkflowArtifactPage: Equatable, Sendable {
    public let runID: String
    public let items: [TaskArtifact]
    public let owners: [WorkflowArtifactOwner]
    public let nextCursor: String?
    public let hasMore: Bool
    public let state: String
    public let reason: String?

    public init?(raw: [String: JSONValue], runID: String) {
        guard JSONValue.object(raw).rendered().utf8.count <= 64 << 10,
              raw["workflow_run_id"]?.stringValue == runID,
              let values = raw["items"]?.arrayValue, values.count <= 50,
              let ownerValues = raw["owners"]?.arrayValue, ownerValues.count <= 50,
              let more = raw["has_more"]?.boolValue,
              let state = raw["state"]?.stringValue, ["available", "unavailable"].contains(state),
              raw["next_cursor"] == .null || raw["next_cursor"]?.stringValue != nil else { return nil }
        let items = values.compactMap { value -> TaskArtifact? in
            guard let object = value.objectValue, let taskID = object["task_id"]?.stringValue,
                  let item = TaskArtifact(raw: object, taskID: taskID), item.workflow != nil else { return nil }
            return item
        }
        let owners = ownerValues.compactMap { $0.objectValue.flatMap(WorkflowArtifactOwner.init(raw:)) }
        let cursor = raw["next_cursor"]?.stringValue
        guard items.count == values.count, owners.count == ownerValues.count,
              Set(items.map(\.id)).count == items.count,
              cursor.map({ !$0.isEmpty && $0.count <= 512 }) ?? !more else { return nil }
        self.runID = runID
        self.items = items
        self.owners = owners
        nextCursor = cursor
        hasMore = more
        self.state = state
        reason = raw["reason"]?.stringValue
    }
}

public extension CtlClient {
    /// Read one page of workflow artifact metadata, optionally scoped to one execution.
    func workflowArtifacts(runId: String, executionId: String? = nil, cursor: String? = nil) async -> Result<WorkflowArtifactPage, ToolError> {
        var options = ["--limit=20"]
        if let executionId { options.append("--execution-id=\(executionId)") }
        if let cursor { options.append("--cursor=\(cursor)") }
        return await result("workflow-artifacts", options: options, positionals: [runId]).flatMap { raw in
            guard let page = WorkflowArtifactPage(raw: raw, runID: runId) else {
                return .failure(.unreadable(tool: "polybridge-ctl", exitCode: 0, stderr: "Malformed workflow artifact metadata page"))
            }
            return .success(page)
        }
    }
}
