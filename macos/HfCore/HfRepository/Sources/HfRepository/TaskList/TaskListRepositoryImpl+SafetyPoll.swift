import Foundation
import MonitorCore

// MARK: - TaskListPollGate

/// Bounds queued tick tasks even if the refresh coordinator's executor is occupied.
final class TaskListPollGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false

    func claim() -> Bool {
        lock.withLock {
            guard !pending else { return false }
            pending = true
            return true
        }
    }

    func release() { lock.withLock { pending = false } }
}

// MARK: - TaskListRepositoryImpl polling

extension TaskListRepositoryImpl {
    var pollIsUrgent: Bool {
        visibility.mainWindowVisible || visibility.menuBarPopoverOpen || listErrorValue != nil
            || tasksValue.contains { $0.status.isRunning || $0.raw["needs_reconciliation"]?.boolValue == true }
            || historyLock.withLock {
                historyStateValue.bootstrapPending || !historyStateValue.catalogState.isReady || historyStateValue.authorityIncomplete
            }
    }

    func enqueuePoll(generation: Int) {
        guard refreshIsCurrent(generation), pollGate.claim() else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { pollGate.release() }
            await evaluateSafetyPoll(generation: generation)
        }
    }

    /// Tick demand is dropped while busy; explicit refresh/action barriers keep their own semantics.
    func evaluateSafetyPoll(generation: Int? = nil) async {
        let captured = generation ?? refreshGeneration()
        defer { countSafetyPollEvaluation() }
        guard refreshIsCurrent(captured), await refreshCoordinator.tryBeginPollIfIdle() else { return }
        // Once claimed, always complete beginPass/endPass, including a superseded initial pass.
        _ = await runRefreshLoop(initialGeneration: captured)
    }
}
