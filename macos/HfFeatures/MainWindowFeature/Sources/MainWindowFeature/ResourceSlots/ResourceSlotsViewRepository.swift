import Combine
import Foundation
import HfRepository
import SwiftEnvironment

// MARK: - ResourceSlotsViewRepository

@MainActor
final class ResourceSlotsViewRepository: ResourceSlotsUseCase {
    @GlobalEnvironment(\.resourceSlotsRepository) private var repository
    var snapshot: ResourceSlotsSnapshot { repository.snapshot }
    func snapshotPublisher() -> AnyPublisher<ResourceSlotsSnapshot, Never> { repository.snapshotPublisher() }
    func acquireObservation() async -> UUID { await repository.acquireObservation() }
    func releaseObservation(_ lease: UUID) async { await repository.releaseObservation(lease) }
    func refresh() async { await repository.refresh() }
    func runtimeChanged() async { await repository.runtimeChanged() }
}
