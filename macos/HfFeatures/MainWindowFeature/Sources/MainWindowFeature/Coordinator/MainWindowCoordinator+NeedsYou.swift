import Foundation

// MARK: - Needs you navigation

extension MainWindowCoordinator {
    func openNeedsYouRun(_ runID: String) { selection = .workflowRun(runID) }
}

// MARK: - NeedsYouRouting

extension MainWindowCoordinator: NeedsYouRouting {
    func showNeedsYou(itemID: String?) {
        selection = .needsYou(itemID: itemID)
    }
}
