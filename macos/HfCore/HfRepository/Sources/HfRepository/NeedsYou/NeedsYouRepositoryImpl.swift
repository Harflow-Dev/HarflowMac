import Combine
import Foundation
import HfUtilities
import MonitorCore

// MARK: - NeedsYouRepositoryImpl

/// Polls the engine on a visibility-driven cadence and publishes one deduplicated snapshot.
/// Acquisition lives in `NeedsYouCore`; this type owns the loop, publication and answer paths.
public final class NeedsYouRepositoryImpl: NeedsYouRepository, @unchecked Sendable {
    static let visibleInterval: TimeInterval = 3
    static let hiddenInterval: TimeInterval = 15

    private let engine: any NeedsYouEngine
    private let approvals: (any ApprovalResponding)?
    private struct CoreScope: Sendable {
        let id: UUID
        let context: ApprovalResponseContext?
        let workflowContext: WorkflowResponseContext?
        let core: NeedsYouCore
    }

    private var scope: CoreScope
    private var scopeRetired = false
    private let runtimeObservation: (@Sendable () -> WorkflowResponseContext?)?
    private let toolEnvironment: any ToolEnvironmentRepository
    private let scheduler: any Scheduling
    private let visibility: any MonitorVisibility
    private let install: any InstallRepository
    private let gate = NeedsYouWakeGate()
    private let lock = NSLock()
    private var loop: Task<Void, Never>?
    private var started = false
    private var subscriptions: [AnyCancellable] = []
    private var published = 0
    private var pendingPublication: NeedsYouCore.Output?
    private var publicationScopeID: UUID?
    private var publishing = false
    private let events = PassthroughSubject<NeedsYouEvent, Never>()

    private var rawSnapshot = NeedsYouSnapshot()
    @Subjected private var snapshotValue = NeedsYouSnapshot()

    /// Creates the production repository over the shared workflow and tool seams.
    public convenience init(
        toolEnvironment: any ToolEnvironmentRepository, workflows: any WorkflowRepository,
        scheduler: any Scheduling, visibility: any MonitorVisibility, install: any InstallRepository, approvals: any ApprovalResponding
    ) {
        self.init(engine: CtlNeedsYouEngine(toolEnvironment: toolEnvironment, workflows: workflows),
                  toolEnvironment: toolEnvironment, scheduler: scheduler, visibility: visibility, install: install, approvals: approvals)
    }

    init(
        engine: any NeedsYouEngine, toolEnvironment: any ToolEnvironmentRepository, scheduler: any Scheduling,
        visibility: any MonitorVisibility, install: any InstallRepository, approvals: (any ApprovalResponding)? = nil,
        runtimeObservation: (@Sendable () -> WorkflowResponseContext?)? = nil
    ) {
        self.runtimeObservation = runtimeObservation
        self.approvals = approvals
        self.install = install
        self.engine = engine
        self.toolEnvironment = toolEnvironment
        self.scheduler = scheduler
        self.visibility = visibility
        let clock = scheduler
        self.scope = CoreScope(id: UUID(), context: nil, workflowContext: nil, core: NeedsYouCore(engine: engine, now: { clock.now() }))
    }

    public var snapshot: NeedsYouSnapshot { approvalEvidence(lock.withLock { rawSnapshot }) }

    private func approvalEvidence(_ snapshot: NeedsYouSnapshot) -> NeedsYouSnapshot {
        guard let approvals else { return snapshot }
        var value = snapshot
        value.items = value.items.map { item in
            var current = item
            if let request = item.approval, let context = item.approvalContext {
                current.approvalOutcome = approvals.retained(request, context: context)
                current.approvalCanRespond = item.approvalCanRespond && approvals.isCurrent(context) && current.approvalOutcome == nil
            }
            return current
        }
        return value
    }

    public func snapshotPublisher() -> AnyPublisher<NeedsYouSnapshot, Never> { $snapshotValue.removeDuplicates().eraseToAnyPublisher() }

    public func eventsPublisher() -> AnyPublisher<NeedsYouEvent, Never> { events.eraseToAnyPublisher() }

    public func start() {
        let admitted = lock.withLock {
            guard !started else { return false }
            started = true
            return true
        }
        guard admitted else { return }
        // Subscription construction may deliver synchronously. Never hold the state lock here.
        let subscriptions = [
            visibility.mainWindowVisiblePublisher().dropFirst().sink { [gate] _ in gate.wake() },
            visibility.menuBarPopoverOpenPublisher().dropFirst().sink { [gate] _ in gate.wake() },
            // Revoke suspended acquisition immediately; the poll loop may be awaiting an engine read.
            install.setupStatePublisher().removeDuplicates().sink { [weak self, gate] state in
                if !state.isReady { self?.retireScope() }
                gate.wake()
            }
        ]
        let loop = Task { [weak self] in
            _ = await self?.toolEnvironment.discoverEnvironment()
            while !Task.isCancelled {
                guard let self else { return }
                await runPass()
                await gate.wait(interval: currentInterval, scheduler: scheduler)
            }
        }
        lock.withLock {
            self.subscriptions = subscriptions
            self.loop = loop
        }
    }

    public func refresh() { gate.wake() }

    private var currentInterval: TimeInterval {
        visibility.mainWindowVisible || visibility.menuBarPopoverOpen ? Self.visibleInterval : Self.hiddenInterval
    }

    /// A runtime epoch owns its acquisition actor and every cursor, source and deferred detail in it.
    /// Superseded actors may finish suspended reads, but can neither contaminate nor publish into a new scope.
    private func coreScope(context: ApprovalResponseContext?, workflowContext: WorkflowResponseContext?) -> (scope: CoreScope, replaced: Bool) {
        lock.withLock {
            guard scopeRetired || scope.context != context || scope.workflowContext != workflowContext else { return (scope, false) }
            scopeRetired = false
            let clock = scheduler
            scope = CoreScope(id: UUID(), context: context, workflowContext: workflowContext, core: NeedsYouCore(engine: engine, now: { clock.now() }))
            published = -1
            return (scope, true)
        }
    }

    private func currentScope() -> CoreScope { lock.withLock { scope } }

    /// Runs one acquisition pass and publishes it. Exposed to tests, which drive passes directly.
    func runPass() async {
        guard install.setupState.isReady else { retireScope(); return }
        let context = try? approvals?.context()
        let workflowContext = observation(context: context)
        let selected = coreScope(context: context, workflowContext: workflowContext)
        guard approvals == nil || context != nil else { return }
        if selected.replaced {
            publish(NeedsYouCore.Output(revision: 0, snapshot: NeedsYouSnapshot(), events: []), from: selected.scope)
        }
        publish(await selected.scope.core.runPass(), from: selected.scope)
    }

    private func publish(_ output: NeedsYouCore.Output, from captured: CoreScope) {
        guard install.setupState.isReady else { return }
        if let context = captured.workflowContext, !isCurrent(context) { return }
        if let approvals {
            guard let context = captured.context, approvals.isCurrent(context) else { return }
        }
        var snapshot = output.snapshot
        snapshot.workflowContext = captured.workflowContext
        snapshot.items = snapshot.items.map { bind($0, to: captured) }
        snapshot.withdrawn = snapshot.withdrawn.map { bind($0, to: captured) }
        let boundEvents = output.events.map { event -> NeedsYouEvent in
            if case .appeared(let item, let baseline) = event { return .appeared(bind(item, to: captured), sourceBaseline: baseline) }
            return event
        }
        let drains = lock.withLock {
            guard scope.id == captured.id, output.revision > published else { return false }
            published = output.revision
            let retainedEvents = publicationScopeID == captured.id ? (pendingPublication?.events ?? []) : []
            pendingPublication = NeedsYouCore.Output(revision: output.revision, snapshot: snapshot, events: retainedEvents + boundEvents)
            publicationScopeID = captured.id
            if publishing { return false }
            publishing = true
            return true
        }
        guard drains else { return }
        drainPublications()
    }

    /// Qualification loss revokes acquisition before enqueueing a display-only invalidation.
    /// This deliberately bypasses ordinary output admission without authorizing nil-context reads.
    private func retireScope() {
        let drains = lock.withLock {
            guard !scopeRetired else { return false }
            scopeRetired = true
            let clock = scheduler
            scope = CoreScope(id: UUID(), context: nil, workflowContext: nil, core: NeedsYouCore(engine: engine, now: { clock.now() }))
            published = -1
            pendingPublication = NeedsYouCore.Output(revision: 0, snapshot: NeedsYouSnapshot(), events: [])
            publicationScopeID = scope.id
            if publishing { return false }
            publishing = true
            return true
        }
        if drains { drainPublications() }
    }

    private func drainPublications() {
        // A single nonblocking drain orders accepted publications; callbacks never run under the state lock.
        while let next = takePublication() {
            lock.withLock { rawSnapshot = next.snapshot }
            let projected = approvalEvidence(next.snapshot)
            if snapshotValue != projected { snapshotValue = projected }
            for event in next.events { events.send(event) }
        }
    }

    private func takePublication() -> NeedsYouCore.Output? {
        lock.withLock {
            guard let next = pendingPublication else { publishing = false; return nil }
            pendingPublication = nil
            return next
        }
    }

    private func bind(_ item: NeedsYouItem, to captured: CoreScope) -> NeedsYouItem {
        var value = item
        if value.kind == .approval { value.approvalContext = captured.context } else { value.workflowContext = captured.workflowContext }
        return value
    }

    private func observation(context: ApprovalResponseContext?) -> WorkflowResponseContext? {
        if let context { return WorkflowResponseContext(runtime: context.runtime, epoch: context.epoch) }
        return runtimeObservation?()
    }

    private func isCurrent(_ context: WorkflowResponseContext) -> Bool {
        let current = observation(context: try? approvals?.context())
        return current == context
    }

    // MARK: - Answers

    public func answer(_ item: NeedsYouItem, text: String, additionalAttempts: Int?) async -> NeedsYouAnswerOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch item.kind {
        case .approval:
            return .failed("Use Approve once or Reject for an approval.")
        case .question:
            guard let decision = item.decisionID, !item.rootRunID.isEmpty, !trimmed.isEmpty else { return .failed("Write an answer first.") }
            if let offered = item.offeredAnswers, !offered.contains(text) { return .failed("Choose one of the offered answers.") }
            return await send(item, root: item.rootRunID, decision: decision, text: offered(item) ? text : trimmed, attempts: nil)
        case .recovery:
            guard !item.rootRunID.isEmpty, !trimmed.isEmpty else { return .failed("Write an answer first.") }
            guard item.attentionCheckpointID != nil else {
                return .failed("This engine cannot identify the displayed checkpoint. Refresh the workflow before continuing.")
            }
            let attempts = item.canAddAttempts ? additionalAttempts.map { max(0, $0) } : nil
            return await send(item, root: item.rootRunID, decision: nil, text: trimmed, attempts: attempts)
        }
    }

    private func offered(_ item: NeedsYouItem) -> Bool { item.offeredAnswers != nil }

    private func send(_ item: NeedsYouItem, root: String, decision: String?, text: String, attempts: Int?) async -> NeedsYouAnswerOutcome {
        let captured = currentScope()
        guard let context = item.workflowContext, captured.workflowContext == context, isCurrent(context) else {
            return .stale(NeedsYouAnswerOutcome.changedMessage)
        }
        do {
            let answer = NeedsYouWorkflowAnswer(root: root, decisionID: decision,
                                                attentionCheckpointID: decision == nil ? item.attentionCheckpointID : nil,
                                                text: text, additionalAttempts: attempts)
            try await engine.resume(answer, runtime: context.runtime, isCurrent: { [weak self] in self?.isCurrent(context) == true })
        } catch let error as ToolError {
            if error.workflowInteractionWinner != nil { await settle(item.id, in: captured) }
            if error.refusalCode == "attention_checkpoint_stale" { refresh() }
            return NeedsYouAnswerOutcome.classify(error)
        } catch {
            return .failed(error.localizedDescription)
        }
        await settle(item.id, in: captured)
        return .accepted
    }

    public func respond(_ item: NeedsYouItem, decision: String) async -> NeedsYouAnswerOutcome {
        guard item.kind == .approval, let shown = item.approval, ["approve", "reject"].contains(decision) else {
            return .failed("This request cannot be approved or rejected.")
        }
        let captured = currentScope()
        if let approvals {
            guard let context = item.approvalContext else { return .changed(nil) }
            let outcome = await approvals.respond(shown, decision: decision, context: context)
            if case .recorded = outcome {
                if captured.context == context { await settle(item.id, in: captured) }
                return .accepted
            }
            refresh()
            return .approvalOutcome(outcome)
        }
        let current: CallerApprovalRequest
        switch await review(shown) {
        case .failure(let refusal): return refusal.value
        case .success(let request): current = request
        }
        do {
            let response = try await engine.respond(current, decision: decision)
            guard current.isConfirmedBy(response, decision: decision) else {
                return .failed("The result could not be confirmed. Your decision will not be retried.")
            }
        } catch let error as ToolError {
            return NeedsYouAnswerOutcome.classify(error)
        } catch { return .failed(error.localizedDescription) }
        await settle(item.id, in: captured)
        return .accepted
    }

    private struct Refusal: Error { let value: NeedsYouAnswerOutcome }

    /// Re-reads the approval and proves it is still the exact request that was displayed.
    private func review(_ shown: CallerApprovalRequest) async -> Result<CallerApprovalRequest, Refusal> {
        let current: CallerApprovalRequest
        do { current = try await engine.approvalDetail(taskID: shown.taskID, requestID: shown.id) } catch let error as ToolError {
            return .failure(Refusal(value: NeedsYouAnswerOutcome.classify(error)))
        } catch { return .failure(Refusal(value: .failed(error.localizedDescription))) }
        if !current.isPending, let responder = current.answeredBy, let timestamp = current.answeredAt,
           ["approve", "reject"].contains(current.text("decision")) {
            return .failure(Refusal(value: .alreadyAnswered(answer: current.text("decision"), answeredBy: responder, answeredAt: timestamp)))
        }
        guard current.isPending, current.complete else { return .failure(Refusal(value: .stale("This request is no longer pending."))) }
        guard current.isSameCurrent(as: shown), current.raw["action"] == shown.raw["action"] else {
            return .failure(Refusal(value: .changed(NeedsYouMapper.approval(request: current, task: nil))))
        }
        let supports = current.interactionOwner == .caller ? (try? await engine.supportsMonitorApprovalResponses()) == true : false
        if current.interactionOwner == .caller, !supports {
            return .failure(Refusal(value: .failed("This engine cannot accept a Harflow response for a caller-owned approval.")))
        }
        guard current.isEligibleForMonitorResponse(supportsCallerResponses: supports, now: scheduler.now()) else {
            return .failure(Refusal(value: .failed("This request cannot be answered from Harflow.")))
        }
        return .success(current)
    }

    private func settle(_ id: String, in captured: CoreScope) async {
        publish(await captured.core.markAnswered(id), from: captured)
        gate.wake()
    }
}

// MARK: - NeedsYouWakeGate

/// Waits for the scheduler tick or an explicit wake, whichever comes first. A wake with no waiter is
/// remembered, so a request made while a pass is running starts the next pass immediately.
final class NeedsYouWakeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var token: AnyCancellable?

    func wake() {
        lock.lock()
        if let continuation {
            self.continuation = nil
            let token = token
            self.token = nil
            lock.unlock()
            token?.cancel()
            continuation.resume()
        } else {
            pending = true
            lock.unlock()
        }
    }

    func wait(interval: TimeInterval, scheduler: any Scheduling) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if pending || Task.isCancelled {
                    pending = false
                    lock.unlock()
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                lock.unlock()
                let cancellable = scheduler.schedule(after: interval) { [weak self] in self?.wake() }
                lock.lock()
                if self.continuation != nil { token = cancellable } else { cancellable.cancel() }
                lock.unlock()
            }
        } onCancel: {
            wake()
        }
    }
}
