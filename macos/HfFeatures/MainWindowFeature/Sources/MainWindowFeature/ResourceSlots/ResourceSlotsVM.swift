import Combine
import Foundation
import HfCommon
import HfRepository
import HfUtilities
import Mockable

// MARK: - ResourceSlotsUseCase

@Mockable
@MainActor
protocol ResourceSlotsUseCase: Sendable {
    var snapshot: ResourceSlotsSnapshot { get }
    func snapshotPublisher() -> AnyPublisher<ResourceSlotsSnapshot, Never>
    func acquireObservation() async -> UUID
    func releaseObservation(_ lease: UUID) async
    func refresh() async
    func runtimeChanged() async
}

// MARK: - ResourceSlotsRouting

@Mockable
@MainActor
protocol ResourceSlotsRouting: Sendable {
    func openResourceSlotOwner(_ destination: ResourceSlotOwnerMetadata.Destination)
}

// MARK: - ResourceSlotsVM

@Observable
@MainActor
final class ResourceSlotsVM: ResourceSlotsViewModel {
    private(set) var presentation = ResourceSlotsPresentation(state: .loading, qualifiers: [])
    private(set) var expandedResourceIDs: Set<String> = []
    private(set) var expandedBlockerIDs: Set<String> = []
    let readingState = ResourceSlotsReadingState()

    @ObservationIgnored private let useCase: any ResourceSlotsUseCase
    @ObservationIgnored private let routing: any ResourceSlotsRouting
    @ObservationIgnored private var didSubscribe = false
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var projectionGeneration = UUID()
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var acquisition: Task<Void, Never>?
    @ObservationIgnored private var projection: Task<Void, Never>?
    @ObservationIgnored private var refreshRequest: Task<Void, Never>?
    @ObservationIgnored private var lease: UUID?
    @ObservationIgnored private var actions: [String: ResourceSlotOwnerMetadata.Destination] = [:]
    @ObservationIgnored private var expandedInitialResource = false
    @ObservationIgnored private var observed = ResourceSlotsSnapshot() {
        didSet {
            guard observed != oldValue else { return }
            if observed.data == nil { actions = [:]; readingState.focusedRowID = nil }
            rebuild()
        }
    }

    init(useCase: any ResourceSlotsUseCase, routing: any ResourceSlotsRouting) {
        self.useCase = useCase
        self.routing = routing
    }

    func didAppear() {
        guard !didSubscribe else { return }
        didSubscribe = true
        let lifecycle = UUID()
        epoch = lifecycle
        useCase.snapshotPublisher()
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .weakAssign(to: \.observed, on: self)
            .store(in: &cancellables)
        observed = useCase.snapshot
        rebuild()
        let useCase = useCase
        acquisition = Task { [weak self] in
            let token = await useCase.acquireObservation()
            guard let self, !Task.isCancelled, didSubscribe, epoch == lifecycle else {
                await useCase.releaseObservation(token)
                return
            }
            lease = token
        }
    }

    func didDisappear() {
        guard didSubscribe else { return }
        didSubscribe = false
        epoch = UUID()
        projectionGeneration = UUID()
        cancellables.removeAll()
        acquisition?.cancel()
        acquisition = nil
        projection?.cancel()
        projection = nil
        refreshRequest?.cancel()
        refreshRequest = nil
        if let lease {
            self.lease = nil
            let useCase = useCase
            Task { await useCase.releaseObservation(lease) }
        }
    }

    func didTapRefresh() {
        guard didSubscribe else { return }
        refreshRequest?.cancel()
        let useCase = useCase
        refreshRequest = Task {
            guard !Task.isCancelled else { return }
            await useCase.refresh()
        }
    }

    func runtimeChanged() {
        let useCase = useCase
        Task { await useCase.runtimeChanged() }
    }

    func didToggleResource(_ id: String) {
        if !expandedResourceIDs.insert(id).inserted { expandedResourceIDs.remove(id) }
    }

    func didToggleBlockers(_ id: String) {
        if !expandedBlockerIDs.insert(id).inserted { expandedBlockerIDs.remove(id) }
    }

    func didOpenOwner(_ rowID: String) {
        guard let destination = actions[rowID] else { return }
        readingState.focusedRowID = rowID
        routing.openResourceSlotOwner(destination)
    }

    private func rebuild() {
        guard didSubscribe else { return }
        projection?.cancel()
        let token = UUID()
        projectionGeneration = token
        let snapshot = observed
        projection = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { ResourceSlotsAssembly.assemble(snapshot) }.value
            guard let self, didSubscribe, !Task.isCancelled, projectionGeneration == token else { return }
            if presentation != result.presentation { presentation = result.presentation }
            actions = result.actions
            if let focused = readingState.focusedRowID, actions[focused] == nil { readingState.focusedRowID = nil }
            if !expandedInitialResource, let first = result.resourceIDs.first {
                expandedResourceIDs.insert(first)
                expandedInitialResource = true
            }
            if snapshot.data != nil {
                expandedResourceIDs.formIntersection(result.resourceIDs)
                expandedBlockerIDs.formIntersection(result.rowIDs)
            }
        }
    }
}
