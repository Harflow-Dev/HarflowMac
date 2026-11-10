import Combine
import Foundation
import HfCommon
import HfRepository
import HfUtilities
import Mockable

// MARK: - PendingLaunchesUseCase

@Mockable
@MainActor
protocol PendingLaunchesUseCase: Sendable {
    var snapshot: PendingLaunchSnapshot { get }
    func snapshotPublisher() -> AnyPublisher<PendingLaunchSnapshot, Never>
    /// Nil when the owner refuses another visibility interest. A successful acquisition starts a read.
    func acquireReadLease() -> PendingLaunchReadLease?
    func releaseReadLease(_ lease: PendingLaunchReadLease)
    func refresh(lease: PendingLaunchReadLease) async
}

// MARK: - PendingLaunchesVM

@Observable
@MainActor
final class PendingLaunchesVM: PendingLaunchesViewModel {
    /// Builds a presentation off the main actor; injectable so a test can control build ordering.
    typealias Builder = @Sendable (PendingLaunchesProjection, Bool, Bool) async -> PendingLaunchesPresentation

    private(set) var presentation = PendingLaunchesPresentation.loading

    @ObservationIgnored private let useCase: any PendingLaunchesUseCase
    @ObservationIgnored private let builder: Builder
    @ObservationIgnored private var didSubscribe = false
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var build: Task<Void, Never>?
    @ObservationIgnored private var refreshRequest: Task<Void, Never>?
    @ObservationIgnored private var lease: PendingLaunchReadLease?
    /// True once this appearance has seen a read in flight; reset with the runtime identity.
    @ObservationIgnored private var didObserveRead = false
    /// A refused acquisition overrides the snapshot until a later acquisition succeeds.
    @ObservationIgnored private var leaseRefused = false {
        didSet { if leaseRefused != oldValue { rebuild() } }
    }

    @ObservationIgnored private var projection = PendingLaunchesProjection(runtimeIdentity: UUID(), inventory: .init()) {
        didSet {
            guard projection != oldValue else { return }
            if projection.runtimeIdentity != oldValue.runtimeIdentity { didObserveRead = false }
            if projection.inventory.isRefreshing { didObserveRead = true }
            rebuild()
        }
    }

    /// Called on the main actor after each build result is processed; `true` when it was applied.
    @ObservationIgnored var didProcessBuild: (@MainActor (Bool) -> Void)?

    init(useCase: any PendingLaunchesUseCase, builder: @escaping Builder) {
        self.useCase = useCase
        self.builder = builder
    }

    convenience init(useCase: any PendingLaunchesUseCase) {
        self.init(useCase: useCase, builder: { projection, refused, observed in
            PendingLaunchesPresentation.make(projection, leaseRefused: refused, didObserveRead: observed)
        })
    }

    func didAppear() {
        guard !didSubscribe else { return }
        didSubscribe = true
        useCase.snapshotPublisher()
            .map(PendingLaunchesProjection.init)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.projection, on: self)
            .store(in: &cancellables)
        isStarting = true
        let initial = useCase.snapshot
        projection = PendingLaunchesProjection(initial)
        if initial.inventory.isRefreshing { didObserveRead = true }
        acquireLease()
        isStarting = false
        rebuild()
    }

    func didDisappear() {
        guard didSubscribe else { return }
        didSubscribe = false
        generation = UUID()
        cancellables.removeAll()
        build?.cancel()
        build = nil
        // Releasing the lease ends the owner's read; the owner's own task is never cancelled from here.
        refreshRequest = nil
        didObserveRead = false
        leaseRefused = false
        if let lease {
            self.lease = nil
            useCase.releaseReadLease(lease)
        }
    }

    func didTapCheckAgain() {
        guard didSubscribe, presentation.checkAction == .enabled else { return }
        guard let lease else {
            acquireLease()
            return
        }
        // Never cancel the previous handle: that would cancel the owner's in-flight traversal.
        let useCase = useCase
        refreshRequest = Task { await useCase.refresh(lease: lease) }
    }

    private func acquireLease() {
        if let acquired = useCase.acquireReadLease() {
            lease = acquired
            leaseRefused = false
        } else {
            leaseRefused = true
        }
    }

    private func rebuild() {
        guard didSubscribe, !isStarting else { return }
        build?.cancel()
        let token = UUID()
        generation = token
        let input = projection
        let refused = leaseRefused
        let observed = didObserveRead
        let builder = builder
        build = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { await builder(input, refused, observed) }.value
            guard let self else { return }
            let applies = didSubscribe && !Task.isCancelled && generation == token
            if applies, presentation != result { presentation = result }
            didProcessBuild?(applies)
        }
    }
}
