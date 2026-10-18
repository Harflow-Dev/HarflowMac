import Foundation
import MonitorCore

// MARK: - HiddenIdleTickCounter

/// Counts safety-poll ticks spent hidden *and* idle: the third one (30 s) is the next allowed
/// refresh. Reset by any visible, busy or due evaluation so a stretch of inactivity is what the
/// 30 s cadence measures.
final class HiddenIdleTickCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Counts one hidden-idle tick; true on every third, which resets the count.
    func advance() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        guard count >= 3 else { return false }
        count = 0
        return true
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        count = 0
    }
}

// MARK: - TaskListRepositoryImpl + safety poll

extension TaskListRepositoryImpl {

    /// One safety-poll evaluation (every 10 s). The refresh triggers are the same everywhere: the
    /// 60 s reconcile is due, a task is running or needs reconciliation, bootstrap is pending,
    /// there is a list error, or the watcher is down. Visible, or with a running/unreconciled
    /// task, they are checked every tick. Hidden *and* idle (nothing running), they are checked
    /// only on every third tick (30 s), so hidden never refreshes more often than visible.
    func evaluateSafetyPoll() async {
        let due = scheduler.now().timeIntervalSince(lastRefresh) >= RefreshTrigger.reconcileInterval
        let running = tasksValue.contains { $0.status.isRunning || $0.raw["needs_reconciliation"]?.boolValue == true }
        let visible = visibility.mainWindowVisible || visibility.menuBarPopoverOpen
        if !visible, !running, !hiddenIdleTicks.advance() { return }
        if visible || running { hiddenIdleTicks.reset() }
        if due || running || historyStateValue.bootstrapPending || listErrorValue != nil || !watcherActive {
            await refresh()
        }
    }
}
