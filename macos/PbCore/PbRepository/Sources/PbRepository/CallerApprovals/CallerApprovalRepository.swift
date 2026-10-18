import MonitorCore
import SwiftEnvironment

public struct CallerApprovalRepository: Sendable {
    private let environment: any ToolEnvironmentRepository
    public init(environment: any ToolEnvironmentRepository) { self.environment = environment }
    public func page(taskID: String?, workflowRunID: String?, cursor: String?) async throws -> CallerApprovalPage {
        let client = try environment.ctl().get()
        return try await client.approvalList(taskID: taskID, workflowRunID: workflowRunID, cursor: cursor).get()
    }

    public func detail(_ request: CallerApprovalRequest) async throws -> CallerApprovalRequest {
        let client = try environment.ctl().get()
        return try await client.approvalGet(taskID: request.taskID, requestID: request.id).get()
    }

    public func respond(_ request: CallerApprovalRequest, decision: String) async throws -> CallerApprovalRequest {
        let client = try environment.ctl().get()
        return try await client.approvalRespond(request, decision: decision).get()
    }
}
