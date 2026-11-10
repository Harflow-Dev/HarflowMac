import Combine
import Foundation
import MonitorCore

// MARK: - TaskHistoryPublication

/// Latest raw listing is synchronously visible, even during a reentrant subscriber callback.
/// A single nonblocking drain delivers whole waves without holding repository/publication locks.
final class TaskHistoryPublication: @unchecked Sendable {
    private let lock = NSLock()
    private let subject = CurrentValueSubject<[TaskInfo], Never>([])
    private var revision: UInt64 = 0
    private var current: [TaskInfo] = []
    private var delivered: [TaskInfo] = []
    private var draining = false
    private var pending = false

    var value: [TaskInfo] { lock.withLock { current } }
    func publisher() -> AnyPublisher<[TaskInfo], Never> { subject.eraseToAnyPublisher() }

    func submit(_ next: [TaskInfo], revision nextRevision: UInt64) {
        let start = lock.withLock {
            guard nextRevision >= revision else { return false }
            revision = nextRevision
            if !Self.equivalent(current, next) { current = next }
            pending = true
            guard !draining else { return false }
            draining = true
            return true
        }
        guard start else { return }
        while let wave = takeWave() {
            // An empty optional content represents an equivalent snapshot.
            if let rows = wave { subject.send(rows) }
        }
    }

    private func takeWave() -> [TaskInfo]?? {
        lock.withLock {
            guard pending else { draining = false; return nil }
            pending = false
            guard !Self.equivalent(delivered, current) else { return .some(nil) }
            delivered = current
            return .some(current)
        }
    }

    private static func equivalent(_ lhs: [TaskInfo], _ rhs: [TaskInfo]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.isEquivalent(to: $1) }
    }
}
