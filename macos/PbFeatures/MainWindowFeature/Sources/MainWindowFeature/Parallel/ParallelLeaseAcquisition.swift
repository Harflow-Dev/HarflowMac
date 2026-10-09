import Foundation
import MonitorCore

// MARK: - ParallelLeaseAcquisition

/// Main-actor acquisition is bounded per turn; yielding allows scrolling to interrupt long chains.
@MainActor
final class ParallelLeaseAcquisition {
    private let acquire: (String) -> Bool
    private let onBurst: ([String], UInt64?) -> Void
    private let onFinish: () -> Void
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var order: [String] = []
    var isSettled: Bool { task == nil }

    init(acquire: @escaping (String) -> Bool, onBurst: @escaping ([String], UInt64?) -> Void, onFinish: @escaping () -> Void) {
        self.acquire = acquire
        self.onBurst = onBurst
        self.onFinish = onFinish
    }

    func update(order: [String], existing: Set<String>) {
        let pending = order.filter { !existing.contains($0) }
        guard self.order != order || (task == nil && !pending.isEmpty) else { return }
        self.order = order
        generation &+= 1
        task?.cancel()
        task = nil
        guard !pending.isEmpty else { return }
        let revision = generation
        task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            var index = 0
            while index < pending.count {
                guard isCurrent(revision) else { return }
                let metric = MonitorMetrics.begin()
                let burst = acquireBurst(pending, startingAt: index, revision: revision)
                index = burst.nextIndex
                let acquired = burst.ids
                onBurst(acquired, metric)
                if index < pending.count { await Task.yield() }
            }
            guard generation == revision else { return }
            task = nil
            onFinish()
        }
    }

    private func acquireBurst(_ pending: [String], startingAt initial: Int, revision: UInt64) -> (nextIndex: Int, ids: [String]) {
        let start = DispatchTime.now().uptimeNanoseconds
        var index = initial
        var acquired: [String] = []
        let end = min(pending.count, index + 4)
        while index < end {
            guard isCurrent(revision) else { break }
            if index > initial, DispatchTime.now().uptimeNanoseconds - start >= 4_000_000 { break }
            let id = pending[index]
            index += 1
            if acquire(id) { acquired.append(id) }
        }
        return (index, acquired)
    }

    private func isCurrent(_ revision: UInt64) -> Bool { !Task.isCancelled && generation == revision }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        order.removeAll()
    }
}
