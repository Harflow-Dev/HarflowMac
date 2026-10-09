import Combine
import Foundation
import MonitorCore

// MARK: - Sidebar subscriptions

extension SidebarVM {
    func subscribeIfNeeded() {
        guard !didSubscribe else { return }
        didSubscribe = true

        useCase.tasksPublisher()
            .receive(on: DispatchQueue.main)
            // Equal listings still provide clock refresh opportunities. The background builder
            // computes ages, then equality-guarded presentation setters suppress unchanged UI.
            .sink { [weak self] tasks in
                guard let self else { return }
                latestTasks = tasks
                // Index construction and pending reveal resolution belong to the worker.
                recompute()
            }
            .store(in: &cancellables)

        useCase.listErrorPublisher()
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] error in
                guard let self else { return }
                latestListError = error
                currentInstallNeed = error.flatMap { useCase.installNeed(for: $0) }
                listErrorMessage = currentInstallNeed == nil ? error?.message : nil
                recomputeInstallBanner()
                recompute()
            }
            .store(in: &cancellables)

        subscribeToInstallState()

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
