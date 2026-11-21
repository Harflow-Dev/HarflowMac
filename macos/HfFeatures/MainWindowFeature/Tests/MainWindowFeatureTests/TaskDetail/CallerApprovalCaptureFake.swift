import Foundation
@testable import MainWindowFeature
import MonitorCore

// MARK: - CallerApprovalCaptureFake

/// A use case over a mutable page of requests that records every response. The page is a reference: a test flips a request
/// to its settled form by assigning `requests`, and the panel's next poll or refresh reads it.
@MainActor
final class CallerApprovalCaptureFake: CallerApprovalUseCase {
    struct PageCall {
        let taskID: String?
        let workflowRunID: String?
        let cursor: String?
    }

    struct Response: Equatable {
        let requestID: String
        let decision: String
    }

    var requests: [CallerApprovalRequest]
    private(set) var responses: [Response] = []
    private(set) var pageCalls: [PageCall] = []
    /// Optional raw run-scoped pages keyed by cursor (`"<first>"` for the initial page).
    /// Their `total` remains the raw tree total, including rows outside the selected root scope.
    var runPages: [String: CallerApprovalPage] = [:]
    var supportsCallerResponses = false
    var suspendsDetails = false
    var suspendsResponses = false
    var suspendsFirstRunPage = false
    var responseResults: [String: CallerApprovalRequest] = [:]
    private(set) var requestedDetails: [String] = []
    private(set) var startedResponses: [String] = []
    private var detailContinuation: CheckedContinuation<CallerApprovalRequest, any Error>?
    private var responseContinuation: CheckedContinuation<CallerApprovalRequest, any Error>?
    private var suspendedRunPageContinuation: CheckedContinuation<CallerApprovalPage, any Error>?
    private var suspendedFirstRunPage = false

    var request: CallerApprovalRequest { requests[0] }
    var responseCount: Int { responses.count }

    init(request: CallerApprovalRequest) { self.requests = [request] }
    init(requests: [CallerApprovalRequest]) { self.requests = requests }

    func page(taskID: String?, workflowRunID: String?, cursor: String?) async throws -> CallerApprovalPage {
        pageCalls.append(PageCall(taskID: taskID, workflowRunID: workflowRunID, cursor: cursor))
        if taskID == nil, workflowRunID != nil {
            if suspendsFirstRunPage, !suspendedFirstRunPage {
                suspendedFirstRunPage = true
                return try await withCheckedThrowingContinuation { suspendedRunPageContinuation = $0 }
            }
            if !runPages.isEmpty { return runPages[cursor ?? "<first>"] ?? CallerApprovalPage(requests: [], total: 0) }
            return CallerApprovalPage(requests: requests, total: requests.count)
        }
        guard let taskID else { return CallerApprovalPage(requests: [], total: 0) }
        let owned = requests.filter { $0.taskID == taskID }
        return CallerApprovalPage(requests: owned, total: owned.count)
    }

    func detail(_ request: CallerApprovalRequest) async throws -> CallerApprovalRequest {
        requestedDetails.append(request.id)
        if suspendsDetails {
            return try await withCheckedThrowingContinuation { detailContinuation = $0 }
        }
        return requests.first { $0.id == request.id } ?? request
    }

    func respond(_ request: CallerApprovalRequest, decision: String) async throws -> CallerApprovalRequest {
        responses.append(Response(requestID: request.id, decision: decision))
        startedResponses.append(request.id)
        if suspendsResponses {
            return try await withCheckedThrowingContinuation { responseContinuation = $0 }
        }
        return responseResults[request.id] ?? request
    }

    func finishDetail(_ request: CallerApprovalRequest) {
        let continuation = detailContinuation
        detailContinuation = nil
        continuation?.resume(returning: request)
    }

    func finishResponse(_ request: CallerApprovalRequest) {
        let continuation = responseContinuation
        responseContinuation = nil
        continuation?.resume(returning: request)
    }

    func finishRunPage(_ page: CallerApprovalPage) {
        let continuation = suspendedRunPageContinuation
        suspendedRunPageContinuation = nil
        continuation?.resume(returning: page)
    }

    func supportsMonitorResponseForCallerApprovals() async throws -> Bool { supportsCallerResponses }
}

// MARK: - Fixture requests

/// A request that satisfies every gate of the controller (complete action, identity, known state, owner and a deadline).
/// `command` fills the Bash `command` field, `extraFields` add further input fields, and `reason` is the agent's stated reason.
func approvalCaptureRequest(owner: String, id: String? = nil, taskID: String = "task-capture", command: String? = nil,
                            extraFields: [String: String] = [:], reason: String? = nil, disposition: String = "pending",
                            createdAt: Double? = nil, workflowMetadata: [String: String] = [:]) -> CallerApprovalRequest {
    let longCommand = command ?? [
        "python3 -c \"open('approval-marker.txt','a').write('APPROVED')\"",
        "--long-command-scroll-probe-abcdefghijklmnopqrstuvwxyz-0123456789-abcdefghijklmnopqrstuvwxyz-0123456789-",
        "abcdefghijklmnopqrstuvwxyz-0123456789-abcdefghijklmnopqrstuvwxyz-0123456789-abcdefghijklmnopqrstuvwxyz-0123456789"
    ].joined()
    var input: [String: JSONValue] = ["command": .string(longCommand)]
    for (key, value) in extraFields { input[key] = .string(value) }
    var raw: [String: JSONValue] = [
        "request_id": .string(id ?? "capture-\(owner)"),
        "task_id": .string(taskID),
        "action_digest": .string(String(repeating: "a", count: 64)),
        "owner_revision": .number(4),
        "generation": .string("generation-capture"),
        "interaction_owner": .string(owner),
        "disposition": .string(disposition),
        "delivery": .string(disposition == "pending" ? "pending" : "sent"),
        "execution_outcome": .string("unknown"),
        "tool_name": .string("Bash"),
        "cwd": .string("/tmp/harflow-capture"),
        "freedom": .string("workspace-write"),
        "scope": .string("caller approval capture"),
        "deadline": .number(Date().addingTimeInterval(600).timeIntervalSince1970),
        "complete": .bool(true),
        "action": .object(["tool_name": .string("Bash"), "input": .object(input)])
    ]
    if let reason { raw["decision_reason"] = .string(reason) }
    if let createdAt { raw["created_at"] = .number(createdAt) }
    for (key, value) in workflowMetadata { raw[key] = .string(value) }
    if disposition != "pending" {
        raw["decision"] = .string("approve")
        raw["effective_decision"] = .string("approve")
        raw["delivered_decision"] = .string("approve")
        raw["responder"] = .string("monitor")
    }
    return CallerApprovalRequest(raw: raw)
}
