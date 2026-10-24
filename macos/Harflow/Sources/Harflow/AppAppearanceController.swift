import AppKit
import Combine
import HfRepository

// MARK: - AppAppearanceController

/// Applies the persisted appearance to the application and keeps it current while the app runs.
@MainActor
final class AppAppearanceController {
    private let applyAppearance: (NSAppearance?) -> Void
    private var cancellable: AnyCancellable?
    private var appliedAppearance: AppAppearance?

    init(
        settingsRepository: any SettingsRepository,
        apply: @escaping (NSAppearance?) -> Void = { NSApplication.shared.appearance = $0 }
    ) {
        self.applyAppearance = apply
        apply(settingsRepository.appAppearance.mapToNativeAppearance)
        self.appliedAppearance = settingsRepository.appAppearance
        self.cancellable = settingsRepository.appAppearancePublisher()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] appearance in
                MainActor.assumeIsolated { self?.apply(appearance) }
            }
    }

    private func apply(_ appearance: AppAppearance) {
        guard appliedAppearance != appearance else { return }
        appliedAppearance = appearance
        applyAppearance(appearance.mapToNativeAppearance)
    }
}

private extension AppAppearance {
    var mapToNativeAppearance: NSAppearance? {
        switch self {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }
}
