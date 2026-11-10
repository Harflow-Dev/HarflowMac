import Combine
import Foundation
import HfRepository
import SwiftEnvironment

// MARK: - PendingLaunchesViewRepository

/// Forwards to the shared pending-launch owner; it holds no state of its own.
@MainActor
final class PendingLaunchesViewRepository: PendingLaunchesUseCase {
    @GlobalEnvironment(\.pendingLaunchRepository) private var repository
    var snapshot: PendingLaunchSnapshot { repository.snapshot }
    func snapshotPublisher() -> AnyPublisher<PendingLaunchSnapshot, Never> { repository.snapshotPublisher() }
    func acquireReadLease() -> PendingLaunchReadLease? { repository.acquireReadLease() }
    func releaseReadLease(_ lease: PendingLaunchReadLease) { repository.releaseReadLease(lease) }
    func refresh(lease: PendingLaunchReadLease) async { await repository.refresh(lease: lease) }
}
