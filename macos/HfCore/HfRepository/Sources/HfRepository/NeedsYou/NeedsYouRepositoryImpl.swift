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
    private let core: NeedsYouCore
    private let toolEnvironment: any ToolEnvironmentRepository
    private let scheduler: any Scheduling
    private let visibility: any MonitorVisibility
    private let gate = NeedsYouWakeGate()
    private let lock = NSLock()
    private var loop: Task<Void, Never>?
    private var subscriptions: [AnyCancellable] = []
    private var published = 0
    private let events = PassthroughSubject<NeedsYouEvent, Never>()

    @Subjected private var snapshotValue = NeedsYouSnapshot()

    /// Creates the production repository over the shared workflow and tool seams.
    public convenience init(
        toolEnvironment: any ToolEnvironmentRepository, workflows: any WorkflowRepository,
        scheduler: any Scheduling, visibility: any MonitorVisibility
    ) {
        self.init(engine: CtlNeedsYouEngine(toolEnvironment: toolEnvironment, workflows: workflows),
                  toolEnvironment: toolEnvironment, scheduler: scheduler, visibility: visibility)
    }

    init(engine: any NeedsYouEngine, toolEnvironment: any ToolEnvironmentRepository, scheduler: any Scheduling, visibility: any MonitorVisibility) {
        self.engine = engine
        self.toolEnvironment = toolEnvironment
        self.scheduler = scheduler
        self.visibility = visibility
        let clock = scheduler
        self.core = NeedsYouCore(engine: engine, now: { clock.now() })
    }

    public var snapshot: NeedsYouSnapshot { snapshotValue }

    public func snapshotPublisher() -> AnyPublisher<NeedsYouSnapshot, Never> { $snapshotValue.removeDuplicates().eraseToAnyPublisher() }

    public func eventsPublisher() -> AnyPublisher<NeedsYouEvent, Never> { events.eraseToAnyPublisher() }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard loop == nil else { return }
        subscriptions = [
            visibility.mainWindowVisiblePublisher().dropFirst().sink { [gate] _ in gate.wake() },
            visibility.menuBarPopoverOpenPublisher().dropFirst().sink { [gate] _ in gate.wake() }
        ]
        loop = Task { [weak self] in
            _ = await self?.toolEnvironment.discoverEnvironment()
            while !Task.isCancelled {
                guard let self else { return }
                await runPass()
                await gate.wait(interval: currentInterval, scheduler: scheduler)
            }
        }
    }

    public func refresh() { gate.wake() }

    private var currentInterval: TimeInterval {
        visibility.mainWindowVisible || visibility.menuBarPopoverOpen ? Self.visibleInterval : Self.hiddenInterval
    }

    /// Runs one acquisition pass and publishes it. Exposed to tests, which drive passes directly.
    func runPass() async {
        publish(await core.runPass())
    }

    private func publish(_ output: NeedsYouCore.Output) {
        let accepted: Bool = lock.withLock {
            guard output.revision > published else { return false }
            published = output.revision
            return true
        }
        guard accepted else { return }
        if snapshotValue != output.snapshot { snapshotValue = output.snapshot }
        for event in output.events { events.send(event) }
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
            // Recovery cannot bind a checkpoint: `workflow-resume <root>` without a decision id follows the root's CURRENT
            // attention source. The engine offers no checkpoint id for attention resumes (HarflowMCP#97), so the
            // checkpoint is re-read immediately before sending. A switch between that read and the command remains possible,
            // exactly as in the run view's recovery control.
            guard await core.currentRecoveryID(root: item.rootRunID) == item.id else {
                return .stale(NeedsYouAnswerOutcome.changedMessage)
            }
            let attempts = item.canAddAttempts ? additionalAttempts.map { max(0, $0) } : nil
            return await send(item, root: item.rootRunID, decision: nil, text: trimmed, attempts: attempts)
        }
    }

    private func offered(_ item: NeedsYouItem) -> Bool { item.offeredAnswers != nil }

    private func send(_ item: NeedsYouItem, root: String, decision: String?, text: String, attempts: Int?) async -> NeedsYouAnswerOutcome {
        do {
            try await engine.resume(root: root, decisionID: decision, text: text, additionalAttempts: attempts)
        } catch let error as ToolError {
            return NeedsYouAnswerOutcome.classify(error)
        } catch {
            return .failed(error.localizedDescription)
        }
        await settle(item.id)
        return .accepted
    }

    public func respond(_ item: NeedsYouItem, decision: String) async -> NeedsYouAnswerOutcome {
        guard item.kind == .approval, let shown = item.approval, ["approve", "reject"].contains(decision) else {
            return .failed("This request cannot be approved or rejected.")
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
        await settle(item.id)
        return .accepted
    }

    private struct Refusal: Error { let value: NeedsYouAnswerOutcome }

    /// Re-reads the approval and proves it is still the exact request that was displayed.
    private func review(_ shown: CallerApprovalRequest) async -> Result<CallerApprovalRequest, Refusal> {
        let current: CallerApprovalRequest
        do { current = try await engine.approvalDetail(taskID: shown.taskID, requestID: shown.id) } catch let error as ToolError {
            return .failure(Refusal(value: NeedsYouAnswerOutcome.classify(error)))
        } catch { return .failure(Refusal(value: .failed(error.localizedDescription))) }
        guard current.isPending, current.complete else { return .failure(Refusal(value: .stale("This request is no longer pending."))) }
        guard current.isSameCurrent(as: shown), current.raw["action"] == shown.raw["action"] else {
            return .failure(Refusal(value: .changed(NeedsYouMapper.approval(request: current, task: nil))))
        }
        guard current.isAwaitingDecision, current.hasKnownState, current.hasValidIdentity,
              (current.deadline ?? .distantPast) > scheduler.now() else {
            return .failure(Refusal(value: .stale("This request is no longer pending.")))
        }
        if !current.isMonitorOwned, (try? await engine.supportsMonitorApprovalResponses()) != true {
            return .failure(Refusal(value: .failed("This engine cannot accept a Harflow response for a caller-owned approval.")))
        }
        return .success(current)
    }

    private func settle(_ id: String) async {
        publish(await core.markAnswered(id))
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
