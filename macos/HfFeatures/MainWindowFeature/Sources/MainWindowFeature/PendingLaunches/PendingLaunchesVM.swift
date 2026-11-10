import Combine
import Foundation
import HfCommon
import HfRepository
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
    /// Nil clears the selection without releasing the lease; a replacement revokes the old selection's reads.
    func bindSelection(taskID: String?, lease: PendingLaunchReadLease) -> PendingLaunchSelection?
    func check(selection: PendingLaunchSelection) async -> PendingLaunchLookup
    func resolveRecorded(selection: PendingLaunchSelection) async -> PendingLaunchRecordedResult
}

// MARK: - PendingLaunchesRouting

/// Navigation the screen needs but the VM must not perform itself. Held weakly by the VM.
@Mockable
@MainActor
protocol PendingLaunchesRouting: AnyObject {
    /// Opens the ordinary task screen for a task the owner admitted through a fresh status read.
    func openRecordedTask(_ taskID: String)
}

// MARK: - Builder values

/// Everything one presentation build reads, captured on the main actor.
struct PendingLaunchesBuildInput: Equatable, Sendable {
    var projection: PendingLaunchesProjection
    var leaseRefused: Bool
    var didObserveRead: Bool
    /// Nil while no launch is selected.
    var detail: PendingLaunchDetailInput?
}

struct PendingLaunchesBuildOutput: Equatable, Sendable {
    var presentation: PendingLaunchesPresentation
    var detail: PendingLaunchDetailPresentation?

    static func make(_ input: PendingLaunchesBuildInput) -> Self {
        .init(
            presentation: .make(input.projection, leaseRefused: input.leaseRefused, didObserveRead: input.didObserveRead),
            detail: input.detail.map { .make(lookup: input.projection.lookup, input: $0) }
        )
    }
}

// MARK: - PendingLaunchesVM

@Observable
@MainActor
final class PendingLaunchesVM: PendingLaunchesViewModel {
    /// Builds a presentation off the main actor; injectable so a test can control build ordering.
    typealias Builder = @Sendable (PendingLaunchesBuildInput) async -> PendingLaunchesBuildOutput

    private(set) var presentation = PendingLaunchesPresentation.loading
    /// The selected launch's detail; nil shows the inventory. Written only by this type and its detail extension.
    var detail: PendingLaunchDetailPresentation?
    /// The row to refocus after Back; written only by this type and its detail extension.
    var focusRowID: String?

    @ObservationIgnored let useCase: any PendingLaunchesUseCase
    @ObservationIgnored let builder: Builder
    @ObservationIgnored weak var routing: (any PendingLaunchesRouting)?
    @ObservationIgnored var didSubscribe = false
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var build: Task<Void, Never>?
    @ObservationIgnored private var refreshRequest: Task<Void, Never>?
    @ObservationIgnored var lease: PendingLaunchReadLease?
    /// True once this appearance has seen a read in flight; reset with the runtime identity.
    @ObservationIgnored private var didObserveRead = false
    /// A refused acquisition overrides the snapshot until a later acquisition succeeds.
    @ObservationIgnored var leaseRefused = false {
        didSet { if leaseRefused != oldValue { rebuild() } }
    }

    // MARK: Selected-launch state (see PendingLaunchesVM+Detail)

    @ObservationIgnored var selection: PendingLaunchSelection?
    /// The owner's runtime identity when the selection was bound (the synchronous snapshot, not the published copy).
    @ObservationIgnored var selectedRuntime: UUID?
    /// Bumped on every selection, Back, disappearance and runtime change; late results compare it.
    @ObservationIgnored var epoch = 0
    @ObservationIgnored var firstCheckSettled = false
    @ObservationIgnored var handoffFailed = false
    /// Checks and recorded-status calls queued or in flight for the current appearance.
    @ObservationIgnored var activeOperations = 0
    @ObservationIgnored var operationSession = UUID()
    /// The newest queued operation. Kept across disappearance and never cancelled: the owner's busy slot
    /// lasts until its earlier ctl call returns.
    @ObservationIgnored var lastOperation: Task<Void, Never>?

    @ObservationIgnored var projection = PendingLaunchesProjection(runtimeIdentity: UUID(), inventory: .init()) {
        didSet {
            guard projection != oldValue else { return }
            if projection.runtimeIdentity != oldValue.runtimeIdentity { didObserveRead = false }
            if projection.inventory.isRefreshing { didObserveRead = true }
            if selection != nil, useCase.snapshot.runtimeIdentity != selectedRuntime { clearSelection() }
            rebuild()
        }
    }

    /// Called on the main actor after each build result is processed; `true` when it was applied.
    @ObservationIgnored var didProcessBuild: (@MainActor (Bool) -> Void)?

    init(useCase: any PendingLaunchesUseCase, routing: (any PendingLaunchesRouting)? = nil, builder: @escaping Builder) {
        self.useCase = useCase
        self.routing = routing
        self.builder = builder
    }

    convenience init(useCase: any PendingLaunchesUseCase, routing: (any PendingLaunchesRouting)? = nil) {
        self.init(useCase: useCase, routing: routing, builder: { PendingLaunchesBuildOutput.make($0) })
    }

    func didAppear() {
        guard !didSubscribe else { return }
        didSubscribe = true
        useCase.snapshotPublisher()
            .map(PendingLaunchesSource.init)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] source in
                guard let self else { return }
                projection = PendingLaunchesProjection(source, lease: lease)
            }
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
        resetSelectionForDisappearance()
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

    func acquireLease() {
        if let acquired = useCase.acquireReadLease() {
            lease = acquired
            leaseRefused = false
        } else {
            leaseRefused = true
        }
    }

    func rebuild() {
        guard didSubscribe, !isStarting else { return }
        build?.cancel()
        let token = UUID()
        generation = token
        let input = PendingLaunchesBuildInput(projection: projection, leaseRefused: leaseRefused,
                                              didObserveRead: didObserveRead, detail: detailInput)
        let builder = builder
        build = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { await builder(input) }.value
            guard let self else { return }
            let applies = didSubscribe && !Task.isCancelled && generation == token
            if applies { apply(result) }
            didProcessBuild?(applies)
        }
    }

    private func apply(_ result: PendingLaunchesBuildOutput) {
        if presentation != result.presentation { presentation = result.presentation }
        // A selection cleared since this build was requested (Back, disappearance) already hid the detail.
        let next = selection == nil ? nil : result.detail
        if detail != next { detail = next }
    }
}
