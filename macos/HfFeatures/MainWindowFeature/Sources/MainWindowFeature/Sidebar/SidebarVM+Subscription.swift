import Combine
import Foundation
import HfRepository
import MonitorCore

// MARK: - Sidebar subscriptions

extension SidebarVM {
    func subscribeIfNeeded() {
        guard !didSubscribe else { return }
        didSubscribe = true
        subscribeToAppAppearance()
        subscribeToNeedsYou()

        useCase.tasksPublisher()
            .receive(on: DispatchQueue.main)
            // The producer already dedupes duration-drifted equivalents, so an emission here is a
            // real change (a started-less running task's duration drift is real state — it is that
            // task's only clock — and still republishes). Time-derived presentation that used to
            // ride the republish pulse ticks on the minute-aligned presentation clock instead.
            .sink { [weak self] tasks in
                guard let self else { return }
                latestTasks = tasks
                // Index construction and pending reveal resolution belong to the worker.
                recompute()
            }
            .store(in: &cancellables)

        subscribeToVisibility()

        useCase.listErrorPublisher()
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] error in
                guard let self else { return }
                latestListError = error
                let dedicatedError = error?.isManagedRuntimeUnavailable == true || error?.isStateRecoveryRefusal == true
                listErrorMessage = dedicatedError ? nil : error?.message
                // Refresh both immediately: `recompute()` returns early while presentation is off.
                emptyStateMessage = computeEmptyStateMessage()
                showsLoadingSkeleton = computeShowsLoadingSkeleton()
                recompute()
            }
            .store(in: &cancellables)

        subscribeToRuntimeAndRecovery()

        useCase.hasListedPublisher()
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] hasListed in
                guard let self else { return }
                latestHasListed = hasListed
                recompute()
            }
            .store(in: &cancellables)

        useCase.titlesPublisher()
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] titles in
                self?.latestTitles = titles
                self?.recompute()
            }
            .store(in: &cancellables)

        subscribeToBackendCatalog()

        routing.selectionPublisher()
            .map { [weak self] destination in (destination, self?.selectionRevision) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] destination, revision in
                guard let self, revision == selectionRevision else { return }
                applyExternalSelection(destination)
            }
            .store(in: &cancellables)

        routing.revealPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reveal in self?.handleReveal(reveal) }
            .store(in: &cancellables)
    }
    
    /// Split out of `subscribeIfNeeded()` to keep that function within the lint length budget.
    private func subscribeToRuntimeAndRecovery() {
        if let recovery = useCase as? any SidebarStoreRecoveryObserving {
            recovery.storeRecoveryPublisher()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.applyStoreRecovery($0) }
                .store(in: &cancellables)
        }
        if let setup = useCase as? any RuntimeSetupObserving {
            setup.runtimeSetupPublisher()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.applyRuntimeSetup($0) }
                .store(in: &cancellables)
        }
    }

    private func subscribeToBackendCatalog() {
        useCase.backendCatalogPublisher()
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] catalog in
                guard let self else { return }
                latestCatalog = catalog
                recompute()
            }
            .store(in: &cancellables)
    }
}
