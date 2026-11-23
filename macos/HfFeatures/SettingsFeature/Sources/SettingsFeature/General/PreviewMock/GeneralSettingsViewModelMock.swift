//
//  GeneralSettingsViewModelMock.swift
//  SettingsFeature
//

#if DEBUG

import Foundation
import HfRepository

// MARK: - GeneralSettingsViewModelMock

/// Preview mock for `GeneralSettingsView`.
@MainActor
final class GeneralSettingsViewModelMock: GeneralSettingsViewModel {
    
    var openWindowOnStart: Bool
    var notifyOnFinish: Bool
    var notifyOnNeedsYou: Bool
    var appAppearance: AppAppearance
    
    init(
        openWindowOnStart: Bool = true,
        notifyOnFinish: Bool = true,
        notifyOnNeedsYou: Bool = true,
        appAppearance: AppAppearance = .system
    ) {
        self.openWindowOnStart = openWindowOnStart
        self.notifyOnFinish = notifyOnFinish
        self.notifyOnNeedsYou = notifyOnNeedsYou
        self.appAppearance = appAppearance
    }
    
    func didAppear() {}
    func didDisappear() {}
    func didToggleOpenWindowOnStart(_ isOn: Bool) { openWindowOnStart = isOn }
    func didToggleNotifyOnFinish(_ isOn: Bool) { notifyOnFinish = isOn }
    func didToggleNotifyOnNeedsYou(_ isOn: Bool) { notifyOnNeedsYou = isOn }
    func didSelectAppearance(_ appearance: AppAppearance) { appAppearance = appearance }
}

#endif
