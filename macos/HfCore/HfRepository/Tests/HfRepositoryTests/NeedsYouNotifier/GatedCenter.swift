import Foundation
@testable import HfRepository
@preconcurrency import UserNotifications

// MARK: - GatedCenter

/// A notification center whose authorization and post can each be held open.
final class GatedCenter: NotificationCentering, @unchecked Sendable {
    enum Gate { case authorization, add }

    private let lock = NSLock()
    private var held: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var reached: Set<String> = []
    private(set) var added: [UNNotificationRequest] = []
    private var removedDeliveredIDs: [String] = []
    private var removedPendingIDs: [String] = []
    private var status: NotificationAuthorization = .allowed
    private var touches = 0

    func hold(_ gate: Gate) { lock.withLock { _ = held.insert("\(gate)") } }

    func release(_ gate: Gate) {
        let toResume = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            held.remove("\(gate)")
            return waiters.removeValue(forKey: "\(gate)") ?? []
        }
        toResume.forEach { $0.resume() }
    }

    func hasReached(_ gate: Gate) -> Bool { lock.withLock { reached.contains("\(gate)") } }

    private func pass(_ gate: Gate) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let wait = lock.withLock { () -> Bool in
                reached.insert("\(gate)")
                guard held.contains("\(gate)") else { return false }
                waiters["\(gate)", default: []].append(continuation)
                return true
            }
            if !wait { continuation.resume() }
        }
    }

    func requestAuthorization(options _: UNAuthorizationOptions) async throws -> Bool {
        lock.withLock { touches += 1 }
        await pass(.authorization)
        return true
    }

    func add(_ request: UNNotificationRequest) async throws {
        lock.withLock { touches += 1 }
        await pass(.add)
        lock.withLock { added.append(request) }
    }

    func removeDelivered(identifiers: [String]) { lock.withLock { touches += 1; removedDeliveredIDs += identifiers } }

    func removePending(identifiers: [String]) { lock.withLock { touches += 1; removedPendingIDs += identifiers } }

    func authorizationStatus() async -> NotificationAuthorization { lock.withLock { touches += 1; return status } }

    func setStatus(_ value: NotificationAuthorization) { lock.withLock { status = value } }

    /// Every call made on the centre, of any kind.
    var touchCount: Int { lock.withLock { touches } }
    var delivered: [String] { lock.withLock { added.map(\.identifier) } }
    var removedDelivered: [String] { lock.withLock { removedDeliveredIDs } }
    var removedPending: [String] { lock.withLock { removedPendingIDs } }
}
