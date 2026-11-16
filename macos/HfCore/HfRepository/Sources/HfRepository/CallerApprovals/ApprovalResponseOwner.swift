import Combine
import Foundation
import MonitorCore
import SwiftEnvironment

// MARK: - ApprovalResponseContext

/// Immutable selected-runtime authority captured with the action being displayed. Never log its runtime.
public struct ApprovalResponseContext: Equatable, Sendable {
    public let runtime: QualificationRuntimeToken
    public let epoch: UUID
    /// Creates a value binding; only the owning responder can admit its current epoch.
    public init(runtime: QualificationRuntimeToken, epoch: UUID) { self.runtime = runtime; self.epoch = epoch }
}

// MARK: - ApprovalResponseOutcome

/// Invocation evidence, retained independently from view mounting and pending ledger observations.
public enum ApprovalResponseOutcome: Equatable, Sendable {
    case recorded(CallerApprovalRequest)
    case refused(ToolError, current: CallerApprovalRequest?)
    case uncertain
    case busy

    /// Exact approved uncertainty copy; no decision may be retried from this state.
    public static let uncertainMessage = "Delivery is unknown. The decision will not be retried."
}

// MARK: - ApprovalResponseRefusal

/// Qualified refusal and fresh public request facts, preserved for feature-specific presentation.
public struct ApprovalResponseRefusal: Error, Sendable {
    public let error: ToolError
    public let current: CallerApprovalRequest?
    public init(error: ToolError, current: CallerApprovalRequest?) { self.error = error; self.current = current }
}

// MARK: - ApprovalResponseBusy

/// Another surface currently holds admission; this is temporary state, not invocation uncertainty.
public struct ApprovalResponseBusy: Error, Sendable { public init() {} }

// MARK: - ApprovalResponding

/// One composition-shared owner for task, Needs you and menu-bar approval responses.
public protocol ApprovalResponding: Sendable {
    func context() throws -> ApprovalResponseContext
    func isCurrent(_ context: ApprovalResponseContext) -> Bool
    func retained(_ request: CallerApprovalRequest, context: ApprovalResponseContext) -> ApprovalResponseOutcome?
    /// Read-only recovery for an explicit Refresh; retained invocation evidence always refuses it.
    func canReviewAgain(_ request: CallerApprovalRequest, context: ApprovalResponseContext) async -> Bool
    func respond(_ request: CallerApprovalRequest, decision: String, context: ApprovalResponseContext) async -> ApprovalResponseOutcome
}

public extension ApprovalResponding {
    func canReviewAgain(_: CallerApprovalRequest, context _: ApprovalResponseContext) async -> Bool { false }
}

// MARK: - ApprovalResponseOwner

/// Atomically admits one attempt for an exact runtime/request identity. No lock spans dependencies or awaits.
public final class ApprovalResponseOwner: ApprovalResponding, @unchecked Sendable {
    private struct Record {
        let runtime: QualificationRuntimeToken
        let request: CallerApprovalRequest
        var outcome: ApprovalResponseOutcome
    }

    private let environment: any ToolEnvironmentRepository
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var epoch = UUID()
    private var records: [Record] = []
    private var subscription: AnyCancellable?

    public init(environment: any ToolEnvironmentRepository, now: @escaping @Sendable () -> Date) {
        self.environment = environment
        self.now = now
    }

    /// Inline notification invalidates closures even when selection returns A→B→A between reads.
    public func bindRuntimeChanges(_ publisher: AnyPublisher<ManagedRuntimeState, Never>) {
        subscription = publisher.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            lock.withLock { epoch = UUID() }
        }
    }

    public func context() throws -> ApprovalResponseContext {
        let captured = lock.withLock { epoch }
        let client = try environment.ctl().get()
        return try lock.withLock {
            guard captured == epoch else { throw Self.changed }
            return ApprovalResponseContext(runtime: QualificationRuntimeToken(client: client), epoch: captured)
        }
    }

    public func isCurrent(_ context: ApprovalResponseContext) -> Bool {
        guard let current = try? self.context() else { return false }
        return current == context
    }

    private static func same(_ first: CallerApprovalRequest, _ second: CallerApprovalRequest) -> Bool {
        first.isSameCurrent(as: second)
    }

    public func retained(_ request: CallerApprovalRequest, context: ApprovalResponseContext) -> ApprovalResponseOutcome? {
        lock.withLock { records.first { $0.runtime == context.runtime && Self.same($0.request, request) }?.outcome }
    }

    public func canReviewAgain(_ request: CallerApprovalRequest, context: ApprovalResponseContext) async -> Bool {
        guard retained(request, context: context) == nil, isCurrent(context),
              let client = try? environment.ctl().get(), QualificationRuntimeToken(client: client) == context.runtime else { return false }
        guard case .success = await review(request, context: context, client: client) else { return false }
        // Another surface may have acquired admission while the read was suspended.
        return isCurrent(context) && retained(request, context: context) == nil
    }

    public func respond(_ request: CallerApprovalRequest, decision: String, context: ApprovalResponseContext) async -> ApprovalResponseOutcome {
        let client: CtlClient
        do { client = try environment.ctl().get() } catch { return .refused(Self.changed, current: nil) }
        guard QualificationRuntimeToken(client: client) == context.runtime, isCurrent(context) else { return .refused(Self.changed, current: nil) }
        guard ["approve", "reject"].contains(decision), request.complete, request.hasValidIdentity,
              request.hasKnownActionEnums, request.hasCoveredAction, request.text("scope") == "exact_action_once" else {
            return .refused(Self.incomplete, current: nil)
        }
        let admission: ApprovalResponseOutcome? = lock.withLock {
            guard epoch == context.epoch else { return .refused(Self.changed, current: nil) }
            if let held = records.first(where: { $0.runtime == context.runtime && Self.same($0.request, request) }) { return held.outcome }
            guard records.count < 256 else {
                return .refused(.refused(code: "approval_capacity",
                                         message: "Approval response evidence is full. This request remains read-only."), current: nil)
            }
            records.append(Record(runtime: context.runtime, request: request, outcome: .busy))
            return nil
        }
        if let admission { return admission }
        // A detached invocation belongs to this owner, not a disappearing UI task's cancellation.
        let outcome = await Task.detached { [self] in
            await perform(request, decision: decision, context: context, client: client)
        }
.value
        lock.withLock {
            if let index = records.firstIndex(where: { $0.runtime == context.runtime && Self.same($0.request, request) }) {
                if outcome.invoked { records[index].outcome = outcome.outcome } else { records.remove(at: index) }
            }
        }
        return outcome.outcome
    }

    private func review(_ shown: CallerApprovalRequest, context: ApprovalResponseContext,
                        client: CtlClient) async -> Result<CallerApprovalRequest, ApprovalResponseRefusal> {
        guard shown.complete, shown.hasValidIdentity, shown.hasKnownActionEnums, shown.hasCoveredAction,
              shown.text("scope") == "exact_action_once" else { return .failure(ApprovalResponseRefusal(error: Self.incomplete, current: nil)) }
        let current: CallerApprovalRequest
        switch await client.approvalGet(taskID: shown.taskID, requestID: shown.id) {
        case .failure(let error): return .failure(ApprovalResponseRefusal(error: error, current: nil))
        case .success(let value): current = value
        }
        guard isCurrent(context) else { return .failure(ApprovalResponseRefusal(error: Self.changed, current: nil)) }
        if current.id == shown.id, current.taskID == shown.taskID, current.digest == shown.digest,
           current.raw["generation"] == shown.raw["generation"], current.raw["action"] == shown.raw["action"],
           current.interactionOwner == shown.interactionOwner, current.complete, current.hasValidIdentity, current.hasKnownState,
           (current.revision ?? 0) > (shown.revision ?? 0), !current.isPending,
           let responder = current.answeredBy, let timestamp = current.answeredAt,
           ["approve", "reject"].contains(current.text("decision")) {
            let error = ToolError.structuredRefusal(code: "approval_error", message: "This request already has an answer.", data: [
                "reason": .string("already_answered"), "interaction": .object([
                    "interaction_id": .string(current.id), "task_id": .string(current.taskID), "action": .string("approval"),
                    "answer": .string(current.text("decision")), "answered_by": .string(responder.rawValue), "answered_at": .number(timestamp)
                ])
            ])
            return .failure(ApprovalResponseRefusal(error: error, current: current))
        }
        guard Self.same(current, shown), current.raw["action"] == shown.raw["action"],
              current.raw["scope"] == shown.raw["scope"] else { return .failure(ApprovalResponseRefusal(error: Self.changed, current: current)) }
        guard current.complete else { return .failure(ApprovalResponseRefusal(error: Self.incomplete, current: current)) }
        guard current.isAwaitingDecision else { return .failure(ApprovalResponseRefusal(error: Self.refusal(.settled), current: current)) }
        guard (current.deadline ?? .distantPast) > now() else { return .failure(ApprovalResponseRefusal(error: Self.refusal(.expired), current: current)) }
        let supports: Bool
        switch await responseCapability(current, client: client) {
        case .success(let supported): supports = supported
        case .failure(let refusal): return .failure(refusal)
        }
        guard current.isEligibleForMonitorResponse(supportsCallerResponses: supports, now: now()) else {
            return .failure(ApprovalResponseRefusal(error: Self.refusal(.unauthorized), current: current))
        }
        guard isCurrent(context) else { return .failure(ApprovalResponseRefusal(error: Self.changed, current: nil)) }
        return .success(current)
    }

    private func responseCapability(_ current: CallerApprovalRequest, client: CtlClient) async -> Result<Bool, ApprovalResponseRefusal> {
        var supports = false
        if current.interactionOwner == .caller {
            switch await client.supportsMonitorResponseForCallerApprovals() {
            case .failure(let error): return .failure(ApprovalResponseRefusal(error: error, current: current))
            case .success(let value): supports = value
            }
            guard supports else { return .failure(ApprovalResponseRefusal(error: Self.refusal(.unsupported), current: current)) }
        }
        return .success(supports)
    }

    private func perform(_ shown: CallerApprovalRequest, decision: String, context: ApprovalResponseContext,
                         client: CtlClient) async -> (outcome: ApprovalResponseOutcome, invoked: Bool) {
        let current: CallerApprovalRequest
        switch await review(shown, context: context, client: client) {
        case .failure(let refusal): return (.refused(refusal.error, current: refusal.current), false)
        case .success(let request): current = request
        }
        // Every command uses this bound client. No environment resolution occurs inside the mutation.
        switch await client.approvalRespond(current, decision: decision) {
        case .success(let response):
            return (current.isConfirmedBy(response, decision: decision) ? .recorded(response) : .uncertain, true)
        case .failure(let error):
            if error.callerApprovalResponseReason != nil || error.callerApprovalWinner != nil {
                return (.refused(error, current: nil), true)
            }
            return (.uncertain, true)
        }
    }

    private static var changed: ToolError { refusal(.notCurrent) }
    private static var incomplete: ToolError { refusal(.incomplete) }
    private static func refusal(_ reason: CallerApprovalResponseReason) -> ToolError {
        .structuredRefusal(code: "approval_error", message: "The request cannot be answered from the displayed action.",
                           data: ["reason": .string(reason.rawValue)])
    }
}

// MARK: - NullApprovalResponseOwner

public struct NullApprovalResponseOwner: ApprovalResponding {
    public init() {}
    public func context() throws -> ApprovalResponseContext { throw ToolError.notFound(tool: "harflow-ctl", searched: []) }
    public func isCurrent(_: ApprovalResponseContext) -> Bool { false }
    public func retained(_: CallerApprovalRequest, context _: ApprovalResponseContext) -> ApprovalResponseOutcome? { nil }
    public func respond(_: CallerApprovalRequest, decision _: String, context _: ApprovalResponseContext) async -> ApprovalResponseOutcome { .uncertain }
}

public extension GlobalValues {
    /// Shared app-session response authority; registered once before constructing consumers.
    @GlobalEntry var approvalResponseOwner: any ApprovalResponding = NullApprovalResponseOwner()
}
