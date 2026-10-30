import Foundation
import MonitorCore

// MARK: - NeedsYouEngine

/// The engine reads and writes Needs you performs, behind a seam so passes can be tested with a
/// counting fake. Every call is one `harflow-ctl` invocation, which is what the per-pass budget counts.
protocol NeedsYouEngine: Sendable {
    /// One page of active workflow headers.
    func workflowPage(cursor: String?) async throws -> HistoryPage
    /// `workflow-status <id> --monitor-view`.
    func workflowStatus(_ runID: String) async throws -> WorkflowMonitorStatus
    /// One page of active tasks.
    func taskPage(cursor: String?) async throws -> TaskHistoryPage
    /// One `status-batch` for up to 100 tasks with a per-id outcome.
    func taskStatuses(_ ids: [String]) async throws -> [String: Result<TaskInfo, ToolError>]
    func approvalPage(taskID: String, cursor: String?) async throws -> CallerApprovalPage
    /// `approval-get --monitor`: the complete current request, action included.
    func approvalDetail(taskID: String, requestID: String) async throws -> CallerApprovalRequest
    /// Whether the selected runtime accepts Monitor responses for caller-owned approvals; cached per runtime.
    func supportsMonitorApprovalResponses() async throws -> Bool
    /// Answers a question (`decisionID` set) or a recovery checkpoint (`decisionID` nil) on a workflow root.
    func resume(root: String, decisionID: String?, text: String, additionalAttempts: Int?) async throws
    func respond(_ request: CallerApprovalRequest, decision: String) async throws -> CallerApprovalRequest
}

// MARK: - CtlNeedsYouEngine

/// Production engine over the shared workflow repository and the selected runtime's `harflow-ctl`.
final class CtlNeedsYouEngine: NeedsYouEngine, @unchecked Sendable {
    private let toolEnvironment: any ToolEnvironmentRepository
    private let workflows: any WorkflowRepository
    private let lock = NSLock()
    private var capability: (runtime: String, supported: Bool)?

    init(toolEnvironment: any ToolEnvironmentRepository, workflows: any WorkflowRepository) {
        self.toolEnvironment = toolEnvironment
        self.workflows = workflows
    }

    func workflowPage(cursor: String?) async throws -> HistoryPage {
        try await workflows.historyPage(cursor: cursor, activeOnly: true, relatedRunID: nil)
    }

    func workflowStatus(_ runID: String) async throws -> WorkflowMonitorStatus {
        WorkflowMonitorStatus(try await workflows.command("status", options: ["--monitor-view"], positionals: [runID]))
    }

    func taskPage(cursor: String?) async throws -> TaskHistoryPage {
        try await toolEnvironment.ctl().get().taskHistoryPage(cursor: cursor, activeOnly: true).get()
    }

    func taskStatuses(_ ids: [String]) async throws -> [String: Result<TaskInfo, ToolError>] {
        try await toolEnvironment.ctl().get().statusBatchOutcomes(ids: ids).get()
    }

    func approvalPage(taskID: String, cursor: String?) async throws -> CallerApprovalPage {
        try await toolEnvironment.ctl().get().approvalList(taskID: taskID, cursor: cursor).get()
    }

    func approvalDetail(taskID: String, requestID: String) async throws -> CallerApprovalRequest {
        try await toolEnvironment.ctl().get().approvalGet(taskID: taskID, requestID: requestID).get()
    }

    func supportsMonitorApprovalResponses() async throws -> Bool {
        let client = try toolEnvironment.ctl().get()
        let runtime = client.executable
        if let cached = lock.withLock({ capability }), cached.runtime == runtime { return cached.supported }
        let supported = try await client.supportsMonitorResponseForCallerApprovals().get()
        lock.withLock { capability = (runtime, supported) }
        return supported
    }

    func resume(root: String, decisionID: String?, text: String, additionalAttempts: Int?) async throws {
        var options = ["--monitor", "--instructions=\(text)"]
        if let decisionID { options.append("--decision-id=\(decisionID)") }
        if let additionalAttempts { options.append("--additional-attempts=\(additionalAttempts)") }
        _ = try await workflows.command("resume", options: options, positionals: [root])
    }

    func respond(_ request: CallerApprovalRequest, decision: String) async throws -> CallerApprovalRequest {
        try await toolEnvironment.ctl().get().approvalRespond(request, decision: decision).get()
    }
}
