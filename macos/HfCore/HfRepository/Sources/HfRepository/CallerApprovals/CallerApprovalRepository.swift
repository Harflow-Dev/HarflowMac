import MonitorCore
import SwiftEnvironment

public struct CallerApprovalRepository: Sendable {
    private let owner: any ApprovalResponding
    private let environment: any ToolEnvironmentRepository
    public init(environment: any ToolEnvironmentRepository, owner: any ApprovalResponding) { self.environment = environment; self.owner = owner }
    public func responseContextValue() throws -> ApprovalResponseContext { try owner.context() }
    public func isResponseContextCurrent(_ context: ApprovalResponseContext) -> Bool { owner.isCurrent(context) }
    public func retainedResponse(_ request: CallerApprovalRequest, context: ApprovalResponseContext) -> ApprovalResponseOutcome? {
        owner.retained(request, context: context)
    }

    /// Explicit read-only recovery; no retained invocation may be cleared by refreshed pending facts.
    public func canReviewAgain(_ request: CallerApprovalRequest, context: ApprovalResponseContext) async -> Bool {
        await owner.canReviewAgain(request, context: context)
    }

    public func page(taskID: String?, workflowRunID: String?, cursor: String?) async throws -> CallerApprovalPage {
        let client = try environment.ctl().get()
        return try await client.approvalList(taskID: taskID, workflowRunID: workflowRunID, cursor: cursor).get()
    }

    public func detail(_ request: CallerApprovalRequest) async throws -> CallerApprovalRequest {
        let client = try environment.ctl().get()
        return try await client.approvalGet(taskID: request.taskID, requestID: request.id).get()
    }

    /// Reads presentation eligibility; submitting a decision independently rechecks the capability.
    public func supportsMonitorResponseForCallerApprovals() async throws -> Bool {
        let client = try environment.ctl().get()
        return try await client.supportsMonitorResponseForCallerApprovals().get()
    }

    public func respond(_ request: CallerApprovalRequest, decision: String, context: ApprovalResponseContext) async throws -> CallerApprovalRequest {
        switch await owner.respond(request, decision: decision, context: context) {
        case .recorded(let response): return response
        case .refused(let error, let current): throw ApprovalResponseRefusal(error: error, current: current)
        case .uncertain: throw ToolError.unknownOutcome(message: ApprovalResponseOutcome.uncertainMessage)
        case .busy: throw ApprovalResponseBusy()
        }
    }
}
