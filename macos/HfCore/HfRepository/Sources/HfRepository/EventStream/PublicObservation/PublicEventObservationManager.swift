import Foundation
import os

// MARK: - PublicEventObservationLease

final class PublicEventObservationLease: Sendable {
    let session: PublicEventObservationSession
    let id: UUID
    private let releaseBody: @Sendable () -> Void
    private let released = OSAllocatedUnfairLock(initialState: false)

    init(session: PublicEventObservationSession, id: UUID, release: @escaping @Sendable () -> Void) {
        self.session = session
        self.id = id
        self.releaseBody = release
    }

    func release() {
        let shouldRelease = released.withLock { value in
            guard !value else { return false }
            value = true
            return true
        }
        if shouldRelease { releaseBody() }
    }

    deinit { release() }
}

// MARK: - PublicEventObservationManager

/// One session per exact task identifier and one global two-operation budget.
final class PublicEventObservationManager: Sendable {
    private struct Entry: Sendable {
        let session: PublicEventObservationSession
        var leases: Set<UUID>
    }

    private let scheduler: any Scheduling
    private let delivery: PublicEventObservationSession.Delivery
    private let budget = EventInitialLoadQueue(limit: 2)
    private let entries = OSAllocatedUnfairLock(initialState: [String: Entry]())

    init(scheduler: any Scheduling, delivery: @escaping PublicEventObservationSession.Delivery) {
        self.scheduler = scheduler
        self.delivery = delivery
    }

    deinit {
        let sessions = entries.withLock { entries in
            let sessions = entries.values.map(\.session)
            entries.removeAll()
            return sessions
        }
        for session in sessions { session.stop() }
    }

    /// The first lease selects the reader for this task/source lifetime; later leases share it.
    func acquire(taskID: String, reader: any PublicEventObservationReader, activityEnabled: Bool = true,
                 publish: @escaping PublicEventObservationSession.Publisher) -> PublicEventObservationLease {
        let leaseID = UUID()
        // Construct outside the manager lock: injected schedulers may execute arbitrary code.
        let candidate = PublicEventObservationSession(taskID: taskID, reader: reader,
                                                      scheduler: scheduler, budget: budget, delivery: delivery, activityEnabled: activityEnabled)
        let session = entries.withLock { entries in
            if var entry = entries[taskID] {
                entry.leases.insert(leaseID)
                entries[taskID] = entry
                return entry.session
            }
            entries[taskID] = Entry(session: candidate, leases: [leaseID])
            return candidate
        }
        if session.id != candidate.id { candidate.stop() }
        session.subscribe(id: leaseID, publish: publish)
        return PublicEventObservationLease(session: session, id: leaseID) { [weak self, weak session] in
            session?.unsubscribe(id: leaseID)
            self?.release(taskID: taskID, sessionID: session?.id, leaseID: leaseID)
        }
    }

    /// Removes entries synchronously, so acquire starts a new source lifetime immediately.
    func invalidateRuntime() {
        let sessions = entries.withLock { entries in
            let sessions = entries.values.map(\.session)
            entries.removeAll()
            // Fence under the manager lock before any replacement can be acquired.
            for session in sessions { session.fenceRuntime() }
            return sessions
        }
        for session in sessions { session.stop() }
    }

    private func release(taskID: String, sessionID: UUID?, leaseID: UUID) {
        let stopped = entries.withLock { entries -> PublicEventObservationSession? in
            guard var entry = entries[taskID], entry.session.id == sessionID,
                  entry.leases.remove(leaseID) != nil else { return nil }
            if entry.leases.isEmpty {
                entries.removeValue(forKey: taskID)
                return entry.session
            }
            entries[taskID] = entry
            return nil
        }
        stopped?.stop()
    }
}
