import Foundation

/// Known engine interaction-owner roles; unknown wire values remain non-actionable.
public enum CallerApprovalOwner: String, Sendable {
    case caller, monitor
}

/// Known approval refusal reasons, separate from the outer ctl error code.
public enum CallerApprovalResponseReason: String, Sendable {
    case notCurrent = "not_current"
    case alreadyAnswered = "already_answered"
    case settled, expired, ownershipLost = "ownership_lost"
    case unauthorized, unsupported, callerUndecidable = "caller_undecidable", incomplete
}

public struct CallerApprovalRequest: Equatable, Identifiable, Sendable {
    public let raw: [String: JSONValue]
    public var id: String { text("request_id") }
    public var taskID: String { text("task_id") }
    public var digest: String { text("action_digest") }
    /// Decodes a known owner without treating future wire values as authorized roles.
    public var interactionOwner: CallerApprovalOwner? { CallerApprovalOwner(rawValue: text("interaction_owner")) }
    public var revision: Int? { raw["owner_revision"]?.intValue }
    public var isPending: Bool { text("disposition") == "pending" && text("delivery") == "pending" }
    public var isMonitorOwned: Bool { interactionOwner == .monitor }
    /// A fresh capability check is still required at mutation time for caller-owned requests.
    public var mayBeAnsweredFromMonitor: Bool { isPending && (interactionOwner == .monitor || interactionOwner == .caller) }
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
    /// Reads the capability for presentation eligibility. `approvalRespond` always performs its
    /// own fresh, operation-scoped handshake before submitting a caller-owned decision.
    func supportsMonitorResponseForCallerApprovals() async -> Result<Bool, ToolError> {
        await VersionInfoClient(executable: executable, environment: environment, context: compatibilityContext, runner: runner)
            .check().map { $0.capabilities.contains(CtlCapability.callerApprovalMonitorRespond) }
    }

    func approvalList(taskID: String? = nil, workflowRunID: String? = nil, cursor: String? = nil) async -> Result<CallerApprovalPage, ToolError> {
        var options = ["--limit=16"]
        if let taskID { options.append("--task-id=\(taskID)") }
        if let workflowRunID { options.append("--workflow-run-id=\(workflowRunID)") }
        if let cursor { options.append("--cursor=\(cursor)") }
        return await result("approval-list", options: options).flatMap { payload in
            guard let values = payload["requests"]?.arrayValue, let total = payload["total"]?.intValue,
                  values.allSatisfy({ $0.objectValue != nil }) else {
                return .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Incomplete approval listing"))
            }
            let requests = values.compactMap { $0.objectValue.map(CallerApprovalRequest.init) }
            return .success(CallerApprovalPage(requests: requests, nextCursor: payload["next_cursor"]?.stringValue, total: total))
        }
    }

    func approvalGet(taskID: String, requestID: String) async -> Result<CallerApprovalRequest, ToolError> {
        await result("approval-get", options: ["--monitor"], positionals: [taskID, requestID]).map(CallerApprovalRequest.init)
    }

    func approvalRespond(_ request: CallerApprovalRequest, decision: String) async -> Result<CallerApprovalRequest, ToolError> {
        guard request.mayBeAnsweredFromMonitor, request.complete, let revision = request.revision,
              ["approve", "reject"].contains(decision) else {
            return .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Inspect the complete current action before responding"))
        }
        let options = ["--monitor", "--action-digest=\(request.digest)", "--owner-revision=\(revision)", "--decision=\(decision)"]
        let capability = request.interactionOwner == .caller ? CtlCapability.callerApprovalMonitorRespond : nil
        return await result("approval-respond", options: options, positionals: [request.taskID, request.id],
                            requiringCapability: capability).map(CallerApprovalRequest.init)
    }
}

public extension ToolError {
    /// Typed approval-specific reason retained in ctl's additive refusal data. Unknown values
    /// intentionally return nil so callers can refresh read-only instead of guessing.
    var callerApprovalResponseReason: CallerApprovalResponseReason? {
        if refusalCode == "caller_undecidable" { return .callerUndecidable }
        guard refusalCode == "approval_error" else { return nil }
        return refusalData?["reason"]?.stringValue.flatMap(CallerApprovalResponseReason.init(rawValue:))
    }
}
