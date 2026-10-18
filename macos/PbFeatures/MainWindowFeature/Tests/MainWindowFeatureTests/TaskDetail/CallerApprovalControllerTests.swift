import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

@MainActor
private final class CallerApprovalFake: CallerApprovalUseCase {
    var pageResult: Result<CallerApprovalPage, Error>
    var detailResult: Result<CallerApprovalRequest, Error>
    var responseResult: Result<CallerApprovalRequest, Error>
    var responseCount = 0
    var delayDetail = false

    init(request: CallerApprovalRequest) {
        self.pageResult = .success(CallerApprovalPage(requests: [request], total: 1))
        self.detailResult = .success(request)
        self.responseResult = .success(request)
    }

    func page(taskID: String?, workflowRunID: String?, cursor: String?) async throws -> CallerApprovalPage { try pageResult.get() }
    func detail(_ request: CallerApprovalRequest) async throws -> CallerApprovalRequest {
        if delayDetail { try await Task.sleep(for: .milliseconds(50)) }
        return try detailResult.get()
    }

    func respond(_ request: CallerApprovalRequest, decision: String) async throws -> CallerApprovalRequest {
        responseCount += 1
        try await Task.sleep(for: .milliseconds(40))
        return try responseResult.get()
    }
}

private func controllerRequest(complete: Bool = true, owner: String = "monitor") -> CallerApprovalRequest {
    var raw: [String: JSONValue] = [
        "request_id": .string("req-1"), "task_id": .string("task-1"), "action_digest": .string(String(repeating: "a", count: 64)),
        "owner_revision": .number(3), "interaction_owner": .string(owner), "disposition": .string("pending"), "delivery": .string("pending"),
        "deadline": .number(Date().addingTimeInterval(600).timeIntervalSince1970)
    ]
    if complete {
        raw["complete"] = .bool(true)
        raw["action"] = .object(["tool_name": .string("Bash"), "input": .object(["command": .string("python3 -c exact")])])
    }
    return CallerApprovalRequest(raw: raw)
}

@MainActor @Suite(.serialized)
struct CallerApprovalControllerTests {
    @Test
    func givenFullInspection_whenActionIdentityChanges_thenDetailIsRefused() async throws {
        let request = controllerRequest()
        let fake = CallerApprovalFake(request: request)
        fake.detailResult = .success(controllerRequest())
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-1", workflowRunID: nil)
        await controller.inspect(request)
        #expect(controller.detail?.id == request.id)
        #expect(controller.isCurrentDetail)

        fake.detailResult = .success(controllerRequest().withDigest("b"))
        await controller.inspect(request)
        #expect(controller.isCurrentDetail == false)
        #expect(controller.error != nil)
    }

    @Test
    func givenStaleInspection_whenTargetChanges_thenOldCallbackIsIgnored() async throws {
        let request = controllerRequest()
        let fake = CallerApprovalFake(request: request)
        fake.delayDetail = true
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-1", workflowRunID: nil)
        let inspection = Task { await controller.inspect(request) }
        await Task.yield()
        await controller.selectTarget(taskID: "task-2", workflowRunID: nil)
        await inspection.value
        #expect(controller.selectedID == nil)
        #expect(controller.detail == nil)
    }

    @Test
    func givenCallerOwnedSelection_whenResponding_thenNoMutationOccurs() async throws {
        let request = controllerRequest(owner: "caller")
        let fake = CallerApprovalFake(request: request)
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-1", workflowRunID: nil)
        await controller.inspect(request)
        await controller.respond("approve")
        #expect(fake.responseCount == 0)
    }

    @Test
    func givenIncompleteSelection_whenResponding_thenNoMutationOccurs() async throws {
        let request = controllerRequest(complete: false)
        let fake = CallerApprovalFake(request: request)
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-1", workflowRunID: nil)
        await controller.inspect(request)
        await controller.respond("approve")
        #expect(fake.responseCount == 0)
    }

    @Test
    func givenDuplicateClicksWhileSubmitting_thenOnlyOneResponseIsSent() async throws {
        let request = controllerRequest()
        let fake = CallerApprovalFake(request: request)
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-1", workflowRunID: nil)
        await controller.inspect(request)
        async let first: Void = controller.respond("approve")
        async let second: Void = controller.respond("approve")
        _ = await (first, second)
        #expect(fake.responseCount == 1)
    }

    @Test
    func givenRefreshError_thenExistingRequestRemainsVisibleWithError() async throws {
        let request = controllerRequest()
        let fake = CallerApprovalFake(request: request)
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-1", workflowRunID: nil)
        fake.pageResult = .failure(TestError.failed)
        await controller.refresh()
        #expect(controller.requests == [request])
        #expect(controller.error != nil)
    }

    @Test
    func givenMixedApprovalHistory_whenRefreshing_thenActiveAndUncertainRequestsLead() async throws {
        let active = controllerRequest().withValues(["request_id": .string("active"), "created_at": .number(30)])
        let uncertain = controllerRequest().withValues([
            "request_id": .string("uncertain"), "created_at": .number(1), "disposition": .string("completed"),
            "delivery": .string("delivery_unknown")
        ])
        let history = controllerRequest().withValues([
            "request_id": .string("history"), "created_at": .number(2), "disposition": .string("completed"),
            "delivery": .string("sent")
        ])
        let fake = CallerApprovalFake(request: active)
        fake.pageResult = .success(CallerApprovalPage(requests: [history, uncertain, active], total: 3))
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-1", workflowRunID: nil)
        #expect(controller.requests.map(\.id) == ["active", "uncertain", "history"])
    }

    @Test
    func givenCompletedResponse_whenResponding_thenDetailsRemainVisibleButActionsDisable() async throws {
        let request = controllerRequest()
        let completed = request.withValues(["disposition": .string("approved"), "delivery": .string("sent")])
        let fake = CallerApprovalFake(request: request)
        fake.responseResult = .success(completed)
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-1", workflowRunID: nil)
        await controller.inspect(request)
        await controller.respond("approve")
        #expect(controller.detail?.id == request.id)
        #expect(controller.isCurrentDetail == false)
        #expect(controller.isSubmitting == false)
    }
}

private enum TestError: Error { case failed }

private extension CallerApprovalRequest {
    func withDigest(_ value: String) -> CallerApprovalRequest {
        var copy = raw
        copy["action_digest"] = .string(value)
        return CallerApprovalRequest(raw: copy)
    }

    func withValues(_ values: [String: JSONValue]) -> CallerApprovalRequest {
        var copy = raw
        for (key, value) in values { copy[key] = value }
        return CallerApprovalRequest(raw: copy)
    }
}
