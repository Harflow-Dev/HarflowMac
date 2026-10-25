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
    var detailCount = 0
    var delayDetail = false
    var supportsResponses = false
    var responseError: Error?
    var pageProvider: ((String?) -> CallerApprovalPage)?
    var detailProvider: ((CallerApprovalRequest) -> CallerApprovalRequest)?

    init(request: CallerApprovalRequest) {
        self.pageResult = .success(CallerApprovalPage(requests: [request], total: 1))
        self.detailResult = .success(request)
        self.responseResult = .success(request)
    }

    func page(taskID: String?, workflowRunID: String?, cursor: String?) async throws -> CallerApprovalPage {
        if let pageProvider { return pageProvider(cursor) }
        return try pageResult.get()
    }

    func detail(_ request: CallerApprovalRequest) async throws -> CallerApprovalRequest {
        detailCount += 1
        if delayDetail { try await Task.sleep(for: .milliseconds(50)) }
        if let detailProvider { return detailProvider(request) }
        return try detailResult.get()
    }

    func respond(_ request: CallerApprovalRequest, decision: String) async throws -> CallerApprovalRequest {
        responseCount += 1
        try await Task.sleep(for: .milliseconds(40))
        if let responseError { throw responseError }
        return try responseResult.get()
    }

    func supportsMonitorResponseForCallerApprovals() async throws -> Bool { supportsResponses }
}

@MainActor
private final class ApprovalBoolBox {
    var value: Bool
    init(_ value: Bool) { self.value = value }
}

private func controllerRequest(complete: Bool = true, owner: String = "monitor") -> CallerApprovalRequest {
    var raw: [String: JSONValue] = [
        "request_id": .string("req-1"), "task_id": .string("task-1"), "action_digest": .string(String(repeating: "a", count: 64)),
        "owner_revision": .number(3), "generation": .string("generation-1"),
        "interaction_owner": .string(owner), "disposition": .string("pending"), "delivery": .string("pending"),
        "execution_outcome": .string("unknown"),
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
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-1", workflowRunID: nil)
        await controller.inspect(request)
        #expect(controller.detail?.id == request.id)
        #expect(controller.isCurrentDetail)

        let changed = request.withValues(["action_digest": .string(String(repeating: "b", count: 64)), "owner_revision": .number(4)])
        fake.pageResult = .success(CallerApprovalPage(requests: [changed], total: 1))
        fake.detailResult = .success(changed.withDigest("c"))
        await controller.refresh()
        #expect(controller.isCurrentDetail == false)
        #expect(controller.cards.first?.canRespond == false)
        #expect(controller.cards.first?.notice != nil)
    }

    @Test
    func givenUnchangedApprovalMetadata_whenRefreshing_thenCurrentDetailIsRetainedWithoutRefetch() async throws {
        let request = controllerRequest()
        let fake = CallerApprovalFake(request: request)
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-1", workflowRunID: nil)
        let detailReads = fake.detailCount
        await controller.inspect(request)
        #expect(controller.isCurrentDetail)
        #expect(fake.detailCount == detailReads)
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
    func givenCallerOwnedSelection_whenCapabilityIsAvailable_thenResponseIsActionable() async throws {
        let request = controllerRequest(owner: "caller")
        let fake = CallerApprovalFake(request: request)
        fake.supportsResponses = true
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-1", workflowRunID: nil)
        await controller.inspect(request)
        #expect(controller.cards.first?.canRespond == true)
        await controller.respond("approve")
        #expect(fake.responseCount == 1)
    }

    @Test
    func givenUnknownApprovalState_whenRefreshed_thenCardIsReadOnly() async throws {
        let request = controllerRequest(owner: "future-owner").withValues(["disposition": .string("future-state")])
        let fake = CallerApprovalFake(request: request)
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-1", workflowRunID: nil)
        #expect(controller.cards.first?.canRespond == false)
        #expect(controller.cards.first?.notice != nil)
    }

    @Test
    func givenPaginationStartsWithSettledRows_whenRefreshing_thenPendingRowsAreStillDiscoveredFirst() async throws {
        let pending = controllerRequest().withValues(["request_id": .string("pending")])
        let settled = controllerRequest().withValues([
            "request_id": .string("settled"), "disposition": .string("completed"), "delivery": .string("sent")
        ])
        let fake = CallerApprovalFake(request: settled)
        fake.pageProvider = { cursor in
            cursor == nil ? CallerApprovalPage(requests: [settled], nextCursor: "next", total: 2)
                : CallerApprovalPage(requests: [pending], nextCursor: nil, total: 2)
        }
        fake.detailResult = .success(settled)
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-1", workflowRunID: nil)
        #expect(controller.cards.map(\.id) == ["pending", "settled"])
        #expect(controller.cards.first?.pending == true)
        controller.setAwaitingDecisionCount(1)
        #expect(controller.hasMorePending == false)
    }

    @Test
    func givenPendingCard_whenEngineSettlesIt_thenCardBecomesNeutralAndCollapsed() async throws {
        let request = controllerRequest()
        let settled = request.withValues(["disposition": .string("completed"), "delivery": .string("sent"), "decision": .string("approve")])
        let fake = CallerApprovalFake(request: request)
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-1", workflowRunID: nil)
        #expect(controller.cards.first?.pending == true)
        fake.pageResult = .success(CallerApprovalPage(requests: [settled], total: 1))
        fake.detailResult = .success(settled)
        await controller.refresh()
        #expect(controller.cards.first?.pending == false)
        #expect(controller.cards.first?.expanded == false)
        #expect(controller.cards.first?.canRespond == false)
        #expect(controller.cards.first?.notice == nil)
    }

    @Test
    func givenPendingRequestBeyondInitialPageChunk_whenLoadingMoreThenRefreshing_thenItRemainsActionable() async throws {
        let pending = controllerRequest(owner: "caller").withValues(["request_id": .string("page-33")])
        let pages = (1 ... 33).reduce(into: [String?: CallerApprovalPage]()) { result, index in
            let request = index == 33 ? pending : controllerRequest().withValues(["request_id": .string("page-\(index)")])
            let cursor = index == 1 ? nil : String(index - 1)
            let next = index == 33 ? nil : String(index)
            result[cursor] = CallerApprovalPage(requests: [request], nextCursor: next, total: 33)
        }
        let fake = CallerApprovalFake(request: pending)
        fake.supportsResponses = true
        fake.pageProvider = { pages[$0]! }
        fake.detailProvider = { $0 }
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-1", workflowRunID: nil)
        #expect(controller.requests.contains { $0.id == "page-33" } == false)
        await controller.refresh(loadMore: true)
        #expect(controller.cards.contains { $0.id == "page-33" && $0.canRespond })
        await controller.refresh()
        #expect(controller.cards.contains { $0.id == "page-33" && $0.canRespond })
    }

    @Test
    func givenUncertainResponse_whenSubmitting_thenItBecomesReadOnlyWithoutRetry() async throws {
        let request = controllerRequest(owner: "caller")
        let fake = CallerApprovalFake(request: request)
        fake.supportsResponses = true
        fake.responseError = ToolError.structuredRefusal(code: "approval_error", message: "delivery unknown",
                                                         data: ["reason": .string("not_current")])
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-1", workflowRunID: nil)
        await controller.inspect(request)
        await controller.respond("approve")
        #expect(fake.responseCount == 1)
        #expect(controller.cards.first?.canRespond == false)
        #expect(controller.cards.first?.notice?.contains("not_current") == false)
        #expect(controller.cards.first?.notice?.localizedCaseInsensitiveContains("refresh") == true)
        await controller.respond("approve")
        #expect(fake.responseCount == 1)
    }

    @Test
    func givenUndecidableCaller_whenSubmitting_thenNoticeExplainsReadOnlyFallback() async throws {
        let request = controllerRequest(owner: "caller")
        let fake = CallerApprovalFake(request: request)
        fake.supportsResponses = true
        fake.responseError = ToolError.refused(code: "caller_undecidable", message: "caller identity unavailable")
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-1", workflowRunID: nil)
        await controller.inspect(request)
        await controller.respond("approve")
        let notice = controller.cards.first?.notice ?? ""
        #expect(notice.localizedCaseInsensitiveContains("read-only") || notice.localizedCaseInsensitiveContains("caller"))
        #expect(notice.contains("caller_undecidable") == false)
    }

    @Test
    func givenOwnerLoss_whenSubmitting_thenNoticeDoesNotPromiseLedgerUnchanged() async throws {
        let request = controllerRequest(owner: "caller")
        let fake = CallerApprovalFake(request: request)
        fake.supportsResponses = true
        fake.responseError = ToolError.structuredRefusal(code: "approval_error", message: "owner gone",
                                                         data: ["reason": .string("ownership_lost")])
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-1", workflowRunID: nil)
        await controller.inspect(request)
        await controller.respond("approve")
        let notice = controller.cards.first?.notice ?? ""
        #expect(notice.localizedCaseInsensitiveContains("owner"))
        #expect(notice.localizedCaseInsensitiveContains("unchanged") == false)
    }

    @Test
    func givenBlockedIdentity_whenSameRequestRefreshes_thenItStaysReadOnlyUntilIdentityChanges() async throws {
        let request = controllerRequest(owner: "caller")
        let fresh = request.withValues([
            "action_digest": .string(String(repeating: "b", count: 64)),
            "owner_revision": .number(4), "generation": .string("generation-2")
        ])
        let fake = CallerApprovalFake(request: request)
        fake.supportsResponses = true
        fake.responseError = ToolError.structuredRefusal(code: "approval_error", message: "stale", data: ["reason": .string("not_current")])
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-1", workflowRunID: nil)
        await controller.inspect(request)
        await controller.respond("approve")
        fake.responseError = nil
        await controller.refresh()
        #expect(controller.cards.first?.canRespond == false)
        fake.pageResult = .success(CallerApprovalPage(requests: [fresh], total: 1))
        fake.detailResult = .success(fresh)
        await controller.refresh()
        #expect(controller.cards.first?.canRespond == true)
    }

    @Test
    func givenCapabilityLossThenRecovery_whenRefreshing_thenActionabilityRecoversWithoutSubmitting() async throws {
        let request = controllerRequest(owner: "caller")
        let fake = CallerApprovalFake(request: request)
        fake.supportsResponses = true
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-1", workflowRunID: nil)
        await controller.inspect(request)
        #expect(controller.cards.first?.canRespond == true)
        fake.supportsResponses = false
        await controller.refresh()
        #expect(controller.cards.first?.canRespond == false)
        fake.supportsResponses = true
        await controller.refresh()
        #expect(controller.cards.first?.canRespond == true)
        #expect(fake.responseCount == 0)
    }

    @Test
    func givenPendingReveal_whenFocusIsAcknowledged_thenFocusTokenIsConsumedButScrollRevealRemains() async throws {
        let request = controllerRequest()
        let fake = CallerApprovalFake(request: request)
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-1", workflowRunID: nil)
        controller.revealPending()
        let token = try #require(controller.cards.first?.focusToken)
        controller.acknowledgeFocus(requestID: request.id, token: token)
        #expect(controller.cards.first?.focusToken == nil)
        #expect(controller.reveal?.token == token)
        controller.acknowledgeScroll(requestID: request.id, token: token)
        #expect(controller.reveal == nil)
        await controller.refresh()
        #expect(controller.cards.first?.focusToken == nil)
        #expect(controller.reveal == nil)
    }

    @Test
    func givenPendingReveal_whenScrollIsAcknowledged_thenFocusIntentRemainsUntilItsOwnAcknowledgement() async throws {
        let request = controllerRequest()
        let fake = CallerApprovalFake(request: request)
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-1", workflowRunID: nil)
        controller.revealPending()
        let token = try #require(controller.cards.first?.focusToken)
        controller.acknowledgeScroll(requestID: request.id, token: token)
        #expect(controller.reveal == nil)
        #expect(controller.cards.first?.focusToken == token)
        controller.acknowledgeFocus(requestID: request.id, token: token)
        #expect(controller.cards.first?.focusToken == nil)
        await controller.refresh()
        #expect(controller.reveal == nil)
        #expect(controller.cards.first?.focusToken == nil)
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
        let completed = request.withValues([
            "disposition": .string("decided"), "delivery": .string("sent"),
            "decision": .string("approve"), "effective_decision": .string("approve"),
            "delivered_decision": .string("approve"), "decided_by": .string("caller"),
            "responder": .string("monitor"), "owner_revision": .number(4)
        ])
        let fake = CallerApprovalFake(request: request)
        fake.responseResult = .success(completed)
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-1", workflowRunID: nil)
        await controller.inspect(request)
        fake.pageResult = .success(CallerApprovalPage(requests: [completed], total: 1))
        fake.detailResult = .success(completed)
        await controller.respond("approve")
        #expect(fake.responseCount == 1)
        #expect(controller.detail?.id == request.id)
        #expect(controller.isCurrentDetail == false)
        #expect(controller.isSubmitting == false)
    }

    @Test
    func givenMalformedSuccessWithWrongIdentityAndNoDecision_whenResponding_thenItBecomesUncertainWithoutRetry() async throws {
        let request = controllerRequest(owner: "caller")
        let malformed = request.withValues([
            "action_digest": .string(String(repeating: "b", count: 64)),
            "disposition": .string("decided"), "delivery": .string("sent"),
            "owner_revision": .number(3), "decision": .null
        ])
        let fake = CallerApprovalFake(request: request)
        fake.supportsResponses = true
        fake.responseResult = .success(malformed)
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-1", workflowRunID: nil)
        await controller.inspect(request)
        await controller.respond("approve")
        #expect(fake.responseCount == 1)
        #expect(controller.cards.first?.canRespond == false)
        #expect(controller.cards.first?.notice?.isEmpty == false)
        await controller.respond("approve")
        #expect(fake.responseCount == 1)
    }

    @Test
    func givenSettledActiveRowMovesBeyondFirstPage_whenRefreshing_thenItsNeutralIdentityIsRetained() async throws {
        let active = controllerRequest().withValues(["request_id": .string("active"), "created_at": .number(20)])
        let history = controllerRequest().withValues([
            "request_id": .string("history"), "created_at": .number(30),
            "disposition": .string("completed"), "delivery": .string("sent")
        ])
        let settled = active.withValues([
            "disposition": .string("decided"), "delivery": .string("sent"),
            "decision": .string("approve"), "effective_decision": .string("approve"),
            "delivered_decision": .string("approve"), "decided_by": .string("caller"),
            "responder": .string("monitor"), "owner_revision": .number(4)
        ])
        let phase = ApprovalBoolBox(false)
        let fake = CallerApprovalFake(request: active)
        fake.pageProvider = { cursor in
            if !phase.value { return CallerApprovalPage(requests: [active, history], total: 2) }
            return cursor == nil ? CallerApprovalPage(requests: [history], nextCursor: "settled-page", total: 2)
                : CallerApprovalPage(requests: [settled], total: 2)
        }
        fake.detailProvider = { $0 }
        fake.responseResult = .success(settled)
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-1", workflowRunID: nil)
        await controller.inspect(active)
        controller.setAwaitingDecisionCount(0)
        phase.value = true
        await controller.respond("approve", requestID: active.id)
        let retained = controller.cards.first { $0.id == active.id }
        #expect(retained?.pending == false)
        #expect(retained?.expanded == false)
        #expect(retained?.canRespond == false)
        #expect(controller.requests.contains { $0.id == active.id })
        #expect(controller.hasMorePending == false)
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
