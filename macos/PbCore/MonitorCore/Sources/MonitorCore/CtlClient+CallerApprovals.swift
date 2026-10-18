import Foundation

public struct CallerApprovalRequest: Equatable, Identifiable, Sendable {
    public let raw: [String: JSONValue]
    public var id: String { text("request_id") }
    public var taskID: String { text("task_id") }
    public var digest: String { text("action_digest") }
    public var revision: Int? { raw["owner_revision"]?.intValue }
    public var isPending: Bool { text("disposition") == "pending" && text("delivery") == "pending" }
    public var isMonitorOwned: Bool { text("interaction_owner") == "monitor" }
    public var deadline: Date? { raw["deadline"]?.doubleValue.map(Date.init(timeIntervalSince1970:)) }
    public var complete: Bool {
        raw["complete"]?.boolValue == true && raw["action"]?.objectValue?["input"]?.objectValue != nil
            && !id.isEmpty && !taskID.isEmpty && !digest.isEmpty && revision != nil
    }
    public init(raw: [String: JSONValue]) { self.raw = raw }
    public func text(_ key: String) -> String { raw[key]?.stringValue ?? "" }
}

public struct CallerApprovalPage: Sendable {
    public let requests: [CallerApprovalRequest]
    public let nextCursor: String?
    public let total: Int
    public init(requests: [CallerApprovalRequest], nextCursor: String? = nil, total: Int) {
        self.requests = requests; self.nextCursor = nextCursor; self.total = total
    }
}

public extension CtlClient {
    func approvalList(taskID: String? = nil, workflowRunID: String? = nil, cursor: String? = nil) async -> Result<CallerApprovalPage, ToolError> {
        var options = ["--limit=16"]
        if let taskID { options.append("--task-id=\(taskID)") }
        if let workflowRunID { options.append("--workflow-run-id=\(workflowRunID)") }
        if let cursor { options.append("--cursor=\(cursor)") }
        return await result("approval-list", options: options).flatMap { payload in
            guard let values = payload["requests"]?.arrayValue, let total = payload["total"]?.intValue,
                  values.allSatisfy({ $0.objectValue != nil }) else {
                return .failure(.unreadable(tool: "polybridge-ctl", exitCode: 0, stderr: "Incomplete approval listing"))
            }
            let requests = values.compactMap { $0.objectValue.map(CallerApprovalRequest.init) }
            return .success(CallerApprovalPage(requests: requests, nextCursor: payload["next_cursor"]?.stringValue, total: total))
        }
    }

    func approvalGet(taskID: String, requestID: String) async -> Result<CallerApprovalRequest, ToolError> {
        await result("approval-get", options: ["--monitor"], positionals: [taskID, requestID]).map(CallerApprovalRequest.init)
    }

    func approvalRespond(_ request: CallerApprovalRequest, decision: String) async -> Result<CallerApprovalRequest, ToolError> {
        guard request.complete, let revision = request.revision, ["approve", "reject"].contains(decision) else {
            return .failure(.unreadable(tool: "polybridge-ctl", exitCode: 0, stderr: "Inspect the complete current action before responding"))
        }
        let options = ["--monitor", "--action-digest=\(request.digest)", "--owner-revision=\(revision)", "--decision=\(decision)"]
        return await result("approval-respond", options: options, positionals: [request.taskID, request.id]).map(CallerApprovalRequest.init)
    }
}
