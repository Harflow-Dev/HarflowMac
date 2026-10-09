import Foundation
import os

// MARK: - EventInitialLoadQueue

/// A shared FIFO budget for initial summary scans and activity reads through their first commit.
/// Cancellation removes queued work; running work keeps its slot until its completion callback.
final class EventInitialLoadQueue: Sendable {
    private typealias Work = @Sendable (@escaping @Sendable () -> Void) -> Void
    private struct State: Sendable {
        var pending: [(UUID, Work)] = []
        var active: Set<UUID> = []
    }

    private let queue = DispatchQueue(label: "dev.polybridge.monitor.initial-loads", qos: .utility)
    private let limit: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(limit: Int = 4) { self.limit = max(1, limit) }

    func submit(id: UUID, work: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {
        queue.async { [self] in
            state.withLock { $0.pending.append((id, work)) }
            drain()
        }
    }

    func cancel(_ id: UUID) {
        queue.async { [self] in state.withLock { $0.pending.removeAll { $0.0 == id } } }
    }

    private func drain() {
        let started = state.withLock { state -> [(UUID, Work)] in
            var started: [(UUID, Work)] = []
            while state.active.count < limit, !state.pending.isEmpty {
                let next = state.pending.removeFirst()
                state.active.insert(next.0)
                started.append(next)
            }
            return started
        }
        for (id, work) in started {
            work { [weak self] in self?.complete(id) }
        }
    }

    private func complete(_ id: UUID) {
        queue.async { [self] in
            guard state.withLock({ $0.active.remove(id) != nil }) else { return }
            drain()
        }
    }
}
