import Combine
import Foundation
import HfRepository

// MARK: - Sidebar appearance

extension SidebarVM {
    var appAppearance: AppAppearance {
        get { access(keyPath: \.appAppearance); return renderedAppAppearance }
        set {
            guard renderedAppAppearance != newValue else { return }
            withMutation(keyPath: \.appAppearance) { renderedAppAppearance = newValue }
            presentationWrites += 1
        }
    }

    func didSelectAppearance(_ appearance: AppAppearance) {
        guard appAppearance != appearance else { return }
        useCase.setAppAppearance(appearance)
        appAppearance = appearance
    }

    func subscribeToAppAppearance() {
        useCase.appAppearancePublisher()
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] appearance in
                guard let self, appAppearance != appearance else { return }
                appAppearance = appearance
            }
            .store(in: &cancellables)
    }
}
