import Combine
import Foundation

// MARK: - TaskListInvalidationSource

/// Timing-only observation: the repository remains responsible for all public reads and facts.
protocol TaskListInvalidationSource: Sendable {
    func observe(isUrgent: @escaping @Sendable () -> Bool,
                 onInvalidated: @escaping @Sendable () -> Void) -> AnyCancellable
}

// MARK: - PollingTaskListInvalidationSource

struct PollingTaskListInvalidationSource: TaskListInvalidationSource {
    let scheduler: any Scheduling

    func observe(isUrgent: @escaping @Sendable () -> Bool,
                 onInvalidated: @escaping @Sendable () -> Void) -> AnyCancellable {
        let state = PollingSubscription(lastInvalidation: scheduler.now())
        let token = scheduler.scheduleRepeating(every: 1) {
            state.tick(now: scheduler.now(), isUrgent: isUrgent, onInvalidated: onInvalidated)
        }
        return AnyCancellable {
            state.cancel()
            token.cancel()
        }
    }
}

/// Cancellation remains effective even when a scheduler retains and later invokes its callback.
private final class PollingSubscription: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var cancelled = false
    private var lastInvalidation: Date

    init(lastInvalidation: Date) { self.lastInvalidation = lastInvalidation }

    func tick(now: Date, isUrgent: @Sendable () -> Bool, onInvalidated: @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        let elapsed = now.timeIntervalSince(lastInvalidation)
        guard isUrgent() || elapsed >= 30 || elapsed < 0 else { return }
        lastInvalidation = now
        onInvalidated()
    }

    func cancel() { lock.withLock { cancelled = true } }
}
