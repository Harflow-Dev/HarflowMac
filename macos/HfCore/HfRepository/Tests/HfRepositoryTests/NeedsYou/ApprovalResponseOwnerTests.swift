import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
import Testing

// MARK: - ApprovalResponseOwnerTests

@Suite struct ApprovalResponseOwnerTests {
    @Test func givenSamePathEnvironmentChange_whenOldDisplayedContextSubmits_thenNoResponseRuns() async throws {
        // given
        let harness = ApprovalOwnerHarness()
        let context = try harness.owner.context()
        // when
        harness.select(environment: ["HOME": "/tmp/approval-owner-b"])
        let result = await harness.owner.respond(harness.request, decision: "approve", context: context)
        // then
        #expect(result.isNotCurrent)
        #expect(harness.runner.responses == 0)
    }

    @Test func givenRuntimeABA_whenOldClosureSubmits_thenEpochRejectsIt() async throws {
        // given
        let harness = ApprovalOwnerHarness()
        let states = CurrentValueSubject<ManagedRuntimeState, Never>(.preparing)
        harness.owner.bindRuntimeChanges(states.eraseToAnyPublisher())
        let context = try harness.owner.context()
        // when
        states.send(.failed("runtime changed"))
        states.send(.preparing)
        let result = await harness.owner.respond(harness.request, decision: "reject", context: context)
        // then
        #expect(result.isNotCurrent)
        #expect(harness.runner.responses == 0)
    }

    @Test func givenSuspendedTaskResponse_whenMenuSurfaceSubmits_thenOnlyOneAttemptRuns() async throws {
        // given
        let harness = ApprovalOwnerHarness()
        harness.runner.suspendResponse = true
        let context = try harness.owner.context()
        let task = Task { await harness.owner.respond(harness.request, decision: "approve", context: context) }
        await waitUntil { harness.runner.responses == 1 }
        // when
        let second = await harness.owner.respond(harness.request, decision: "reject", context: context)
        harness.runner.release()
        _ = await task.value
        // then
        #expect(second == .busy)
        #expect(harness.runner.responses == 1)
    }

    @Test func givenUncertainInvocation_whenRemountRefreshAndRuntimeReturn_thenNoDuplicateResponseRuns() async throws {
        // given
        let harness = ApprovalOwnerHarness()
        harness.runner.failResponse = true
        let context = try harness.owner.context()
        #expect(await harness.owner.respond(harness.request, decision: "approve", context: context) == .uncertain)
        // when — another adapter and a fresh epoch still address the same persisted request identity.
        let states = CurrentValueSubject<ManagedRuntimeState, Never>(.preparing)
        harness.owner.bindRuntimeChanges(states.eraseToAnyPublisher())
        states.send(.failed("runtime changed"))
        states.send(.preparing)
        let remounted = try harness.owner.context()
        let result = await harness.owner.respond(harness.request, decision: "reject", context: remounted)
        // then
        #expect(result == .uncertain)
        #expect(harness.owner.retained(harness.request, context: remounted) == .uncertain)
        #expect(harness.runner.responses == 1)
    }

    @Test(arguments: ["action_digest", "owner_revision", "action", "task_id", "request_id"])
    func givenFreshDetailDiffers_whenAdmissionRechecksExactAction_thenNoMutationRuns(field: String) async throws {
        // given
        let harness = ApprovalOwnerHarness()
        var raw = harness.request.raw
        raw[field] = field == "owner_revision" ? .number(9)
            : field == "action" ? .object(["input": .object(["command": .string("different")])]) : .string("different")
        harness.runner.detail = CallerApprovalRequest(raw: raw)
        // when
        let result = await harness.owner.respond(harness.request, decision: "approve", context: try harness.owner.context())
        // then
        #expect(result.isNotCurrent)
        #expect(harness.runner.responses == 0)
    }

    @Test func givenChangedActionAlreadyAnswered_whenFreshDetailReturns_thenWinnerIsNotAttributedToOldAction() async throws {
        // given
        let harness = ApprovalOwnerHarness()
        var raw = harness.request.raw
        raw["action_digest"] = .string("different")
        raw["disposition"] = .string("decided")
        raw["delivery"] = .string("sent")
        raw["decision"] = .string("approve")
        raw["responder"] = .string("caller")
        raw["decided_at"] = .number(123)
        raw["owner_revision"] = .number(2)
        harness.runner.detail = CallerApprovalRequest(raw: raw)
        // when
        let result = await harness.owner.respond(harness.request, decision: "approve", context: try harness.owner.context())
        // then
        #expect(result.isNotCurrent)
        if case .refused(let error, _) = result { #expect(error.callerApprovalWinner == nil) }
        #expect(harness.runner.responses == 0)
    }

    @Test func givenDeadlinePassedWhenRechecked_whenAdmitted_thenNoMutationRuns() async throws {
        // given
        let harness = ApprovalOwnerHarness(owner: "caller", now: { Date(timeIntervalSince1970: 5000) })
        // when
        let result = await harness.owner.respond(harness.request, decision: "approve", context: try harness.owner.context())
        // then
        guard case .refused(let error, _) = result else { Issue.record("Expected expiry refusal"); return }
        #expect(error.callerApprovalResponseReason == .expired)
        #expect(harness.runner.responses == 0)
    }

    @Test func givenCallerCapabilityMissing_whenAdmitted_thenNoMutationRuns() async throws {
        // given
        let harness = ApprovalOwnerHarness(owner: "caller")
        harness.runner.supportsCaller = false
        // when
        let result = await harness.owner.respond(harness.request, decision: "approve", context: try harness.owner.context())
        // then
        guard case .refused(let error, _) = result else { Issue.record("Expected capability refusal"); return }
        #expect(error.callerApprovalResponseReason == .unsupported)
        #expect(harness.runner.responses == 0)
    }

    @Test func givenCapabilityReadFailure_whenFreshReadRecovers_thenNoAttemptWasTombstoned() async throws {
        // given
        let harness = ApprovalOwnerHarness(owner: "caller")
        harness.runner.supportsCaller = false
        let context = try harness.owner.context()
        _ = await harness.owner.respond(harness.request, decision: "approve", context: context)
        // when
        harness.runner.supportsCaller = true
        let result = await harness.owner.respond(harness.request, decision: "approve", context: context)
        // then
        guard case .recorded = result else { Issue.record("Expected explicit reviewed response after capability recovery"); return }
        #expect(harness.runner.responses == 1)
    }

    @Test func givenNeverInvokedCapabilityRefusal_whenExplicitFreshReviewSucceeds_thenSameIdentityCanBeReviewedWithoutMutation() async throws {
        // given
        let harness = ApprovalOwnerHarness(owner: "caller")
        let context = try harness.owner.context()
        harness.runner.supportsCaller = false
        _ = await harness.owner.respond(harness.request, decision: "approve", context: context)
        #expect(await harness.owner.canReviewAgain(harness.request, context: context) == false)
        // when
        harness.runner.supportsCaller = true
        #expect(await harness.owner.canReviewAgain(harness.request, context: context))
        // then
        #expect(harness.runner.responses == 0)
        guard case .recorded = await harness.owner.respond(harness.request, decision: "approve", context: context) else {
            Issue.record("Expected one explicitly submitted decision after fresh review"); return
        }
        #expect(harness.runner.responses == 1)
    }

    @Test func givenExplicitReviewSuspends_whenAnotherSurfaceAcquiresAndBecomesUncertain_thenRecoveryCannotClearInvocationEvidence() async throws {
        // given
        let harness = ApprovalOwnerHarness()
        let context = try harness.owner.context()
        harness.runner.suspendNextDetail = true
        harness.runner.failResponse = true
        let review = Task { await harness.owner.canReviewAgain(harness.request, context: context) }
        await waitUntil { harness.runner.detailWaiting }
        // when
        #expect(await harness.owner.respond(harness.request, decision: "approve", context: context) == .uncertain)
        harness.runner.releaseDetail()
        // then
        #expect(await review.value == false)
        #expect(await harness.owner.canReviewAgain(harness.request, context: context) == false)
        #expect(harness.runner.responses == 1)
        #expect(harness.owner.retained(harness.request, context: context) == .uncertain)
    }

    @Test func givenGenericPostInvocationRefusal_whenSubmittedAgain_thenItStaysUncertain() async throws {
        // given
        let harness = ApprovalOwnerHarness()
        harness.runner.genericFailure = true
        let context = try harness.owner.context()
        // when
        let first = await harness.owner.respond(harness.request, decision: "approve", context: context)
        let second = await harness.owner.respond(harness.request, decision: "reject", context: context)
        // then
        #expect(first == .uncertain && second == .uncertain)
        #expect(harness.runner.responses == 1)
    }

    @Test(arguments: ["approve", "reject"], ["caller", "monitor"])
    func givenPersistedWinner_whenFreshDetailIsRead_thenChannelDecisionAndTimeSurvive(decision: String, channel: String) async throws {
        // given
        let harness = ApprovalOwnerHarness()
        var raw = harness.request.raw
        raw["disposition"] = .string("decided")
        raw["delivery"] = .string("sent")
        raw["decision"] = .string(decision)
        raw["responder"] = .string(channel)
        raw["decided_at"] = .number(123)
        raw["owner_revision"] = .number(2)
        harness.runner.detail = CallerApprovalRequest(raw: raw)
        // when
        let result = await harness.owner.respond(harness.request, decision: "approve", context: try harness.owner.context())
        // then
        guard case .refused(let error, _) = result else { Issue.record("Expected winning answer"); return }
        #expect(error.callerApprovalWinner?.decision == decision)
        #expect(error.callerApprovalWinner?.answeredBy.rawValue == channel)
        #expect(error.callerApprovalWinner?.answeredAt == 123)
        #expect(harness.runner.responses == 0)
    }
}

private extension ApprovalResponseOutcome {
    var isNotCurrent: Bool {
        guard case .refused(let error, _) = self else { return false }
        return error.callerApprovalResponseReason == .notCurrent
    }
}

// MARK: - ApprovalOwnerHarness

private final class ApprovalOwnerHarness: @unchecked Sendable {
    let request: CallerApprovalRequest
    let runner: ApprovalOwnerRunner
    let owner: ApprovalResponseOwner
    private let environment: MockToolEnvironmentRepository
    private let client: LockedBox<CtlClient>

    init(owner: String = "monitor", now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1000) }) {
        var raw = approval(owner: owner).raw
        raw["deadline"] = .number(2000)
        raw["scope"] = .string("exact_action_once")
        self.request = CallerApprovalRequest(raw: raw)
        self.runner = ApprovalOwnerRunner(request)
        self.environment = MockToolEnvironmentRepository()
        self.client = LockedBox(CtlClient(executable: "/bin/approval-test", environment: ["HOME": "/tmp/approval-owner"], runner: runner))
        let selected = client
        given(environment).ctl().willProduce { .success(selected.value) }
        self.owner = ApprovalResponseOwner(environment: environment, now: now)
    }

    func select(environment: [String: String]) {
        client.mutate { $0 = CtlClient(executable: "/bin/approval-test", environment: environment, runner: runner) }
    }
}

// MARK: - ApprovalOwnerRunner

private final class ApprovalOwnerRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private var detailWaiter: CheckedContinuation<Void, Never>?
    var suspendNextDetail = false
    var detailWaiting: Bool { lock.withLock { detailWaiter != nil } }
    var detail: CallerApprovalRequest
    var supportsCaller = true
    var failResponse = false
    var genericFailure = false
    var suspendResponse = false
    var responses: Int { lock.withLock { count } }
    init(_ request: CallerApprovalRequest) { self.detail = request }

    func releaseDetail() {
        let held = lock.withLock { let held = detailWaiter; detailWaiter = nil; return held }
        held?.resume()
    }

    func release() { lock.withLock { let held = waiter; waiter = nil; held?.resume() } }

    func run(
        executable _: String, arguments: [String], environment: [String: String], currentDirectory _: String?, timeout _: Double
    ) async -> Result<ProcessOutput, ToolError> {
        if arguments.first == "version-info" {
            let root = (environment["HOME"] ?? "/tmp/approval-owner") + "/.harflow"
            let caps = supportsCaller ? ["ctl.v1", "caller-approvals.monitor-respond.v1"] : ["ctl.v1"]
            return .success(stdout(JSONValue.object([
                "product": .string("harflow"), "format": .string("harflow.version-info"), "v": .number(1),
                "product_version": .string("0.0.14"), "component": .string("engine"), "state_root": .string(root),
                "contracts": .object(["ctl": .object(["format": .string("harflow.ctl"), "v": .number(1)])]),
                "capabilities": .array(caps.map(JSONValue.string)), "os": .string("darwin"), "architecture": .string("arm64")
            ])
.rendered()))
        }
        if arguments.first == "approval-get" {
            let suspend = lock.withLock { let suspend = suspendNextDetail; suspendNextDetail = false; return suspend }
            if suspend { await withCheckedContinuation { continuation in lock.withLock { detailWaiter = continuation } } }
        }
        if arguments.first == "approval-respond" {
            if suspendResponse {
                await withCheckedContinuation { continuation in lock.withLock { waiter = continuation; count += 1 } }
            } else { lock.withLock { count += 1 } }
            if genericFailure { return .failure(.refused(code: "generic_error", message: "No qualified delivery receipt")) }
            if failResponse { return .failure(.unknownOutcome(message: "transport closed")) }
            var raw = detail.raw
            raw["owner_revision"] = .number(Double((detail.revision ?? 0) + 1))
            raw["disposition"] = .string("decided")
            raw["delivery"] = .string("sent")
            raw["decided_by"] = .string("caller")
            raw["responder"] = .string("monitor")
            raw["decision"] = .string(arguments.contains("--decision=reject") ? "reject" : "approve")
            return output(raw)
        }
        return output(detail.raw)
    }

    private func output(_ raw: [String: JSONValue]) -> Result<ProcessOutput, ToolError> {
        .success(stdout(JSONValue.object([
            "product": .string("harflow"), "format": .string("harflow.ctl"), "v": .number(1),
            "product_version": .string("0.0.14"), "result": .object(raw)
        ])
.rendered()))
    }
}
