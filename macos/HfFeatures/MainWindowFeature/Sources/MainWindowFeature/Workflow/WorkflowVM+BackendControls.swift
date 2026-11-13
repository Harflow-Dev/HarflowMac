import Combine
import Foundation
import HfRepository

// MARK: - WorkflowUseCase defaults

extension WorkflowUseCase {
    var backendCatalog: BackendCatalog { .empty }
    func backendCatalogPublisher() -> AnyPublisher<BackendCatalog, Never> { Just(.empty).eraseToAnyPublisher() }
}

// MARK: - WorkflowVM + backend controls

extension WorkflowVM {
    /// Seeds `backendControls` from the current catalog and follows its publisher until `didDisappear`.
    func startBackendControls() {
        applyCatalog(useCase.backendCatalog)
        catalogSubscription = useCase.backendCatalogPublisher().receive(on: DispatchQueue.main).sink { [weak self] catalog in
            self?.applyCatalog(catalog)
        }
    }

    /// Run-option controls per harness, from the engine-reported catalog; every control is unknown
    /// until the catalog is available. Written only when it changes.
    func applyCatalog(_ catalog: BackendCatalog) {
        let controls = Dictionary(catalog.entries.map { ($0.backend, catalog.controls(for: $0.backend)) }, uniquingKeysWith: { first, _ in first })
        if backendControls != controls { backendControls = controls }
    }
}
