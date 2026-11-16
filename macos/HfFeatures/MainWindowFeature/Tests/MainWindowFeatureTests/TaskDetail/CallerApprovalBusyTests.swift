import Foundation
import HfRepository
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - CallerApprovalBusyTests

@MainActor @Suite struct CallerApprovalBusyTests {
    @Test func givenOtherSurfaceBusyThenPreflightFails_whenFreshReadRuns_thenTaskDecisionsBecomeAvailableAgain() async throws {
        // given
        var raw = try approvalStateRequest("ctl-approval-get-claude-bash").raw
        raw["deadline"] = .number(Date().addingTimeInterval(600).timeIntervalSince1970)
        let fake = EphemeralApprovalUseCase(request: CallerApprovalRequest(raw: raw))
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: fake.request.taskID, workflowRunID: nil)
        // when — a concurrent surface takes admission after the card was displayed.
        await controller.respond("approve", requestID: fake.request.id)
        #expect(controller.cards.first?.canRespond == false)
        fake.held = nil // Other surface's preflight failed; no mutation was invoked.
        await controller.refresh()
        // then
        #expect(controller.cards.first?.canRespond == true)
        #expect(controller.cards.first?.showsDecisionControls == true)
        #expect(controller.cards.first?.notice == nil)
        #expect(fake.responseCalls == 1)
    }

    @Test func givenNeverInvokedCapabilityFailure_whenExplicitSameIdentityReviewRecovers_thenTaskClearsOnlyAfterFreshProof() async throws {
        // given
        var raw = try approvalStateRequest("ctl-approval-get-claude-bash").raw
        raw["deadline"] = .number(Date().addingTimeInterval(600).timeIntervalSince1970)
        let fake = EphemeralApprovalUseCase(request: CallerApprovalRequest(raw: raw))
        fake.responseFailure = ApprovalResponseRefusal(error: .structuredRefusal(code: "approval_error", message: "unsupported",
                                                                                data: ["reason": .string("unsupported")]), current: nil)
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: fake.request.taskID, workflowRunID: nil)
        await controller.respond("approve", requestID: fake.request.id)
        #expect(controller.cards.first?.canRespond == false)
        // when
        await controller.refresh(recoverPreflight: true)
        #expect(controller.cards.first?.canRespond == false)
        fake.freshReviewSucceeded = true
        await controller.refresh(recoverPreflight: true)
        // then
        #expect(controller.cards.first?.canRespond == true)
        #expect(fake.reviewCalls == 2)
        #expect(fake.responseCalls == 1)
    }

}

// MARK: - EphemeralApprovalUseCase

@MainActor private final class EphemeralApprovalUseCase: CallerApprovalUseCase {
    let request: CallerApprovalRequest
    let context = ApprovalResponseContext(runtime: QualificationRuntimeToken(client: CtlClient(executable: "/fixture/ctl", environment: [:])), epoch: UUID())
    var held: ApprovalResponseOutcome?
    var responseCalls = 0
    var responseFailure: Error?
    var freshReviewSucceeded = false
    var reviewCalls = 0
    func canReviewAgain(_: CallerApprovalRequest, context _: ApprovalResponseContext) async -> Bool {
        reviewCalls += 1; return freshReviewSucceeded && held == nil
    }

    init(request: CallerApprovalRequest) { self.request = request }
    func responseContext() throws -> ApprovalResponseContext? { context }
    func isResponseContextCurrent(_ context: ApprovalResponseContext) -> Bool { self.context == context }
    func retainedResponse(_: CallerApprovalRequest, context _: ApprovalResponseContext) -> ApprovalResponseOutcome? { held }
    func page(taskID _: String?, workflowRunID _: String?, cursor _: String?) async throws -> CallerApprovalPage {
        CallerApprovalPage(requests: [request], total: 1)
    }

    func detail(_: CallerApprovalRequest) async throws -> CallerApprovalRequest { request }
    func supportsMonitorResponseForCallerApprovals() async throws -> Bool { true }
    func respond(_: CallerApprovalRequest, decision _: String) async throws -> CallerApprovalRequest {
        responseCalls += 1
        if let responseFailure { throw responseFailure }
        held = .busy
        throw ApprovalResponseBusy()
    }
}
