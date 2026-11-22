//
//  GeneralSettingsViewModelMock.swift
//  SettingsFeature
//

#if DEBUG

import Foundation

// MARK: - GeneralSettingsViewModelMock

/// Preview mock for `GeneralSettingsView`.
@MainActor
final class GeneralSettingsViewModelMock: GeneralSettingsViewModel {
    
    var openWindowOnStart: Bool
    var notifyOnFinish: Bool
    var notifyOnNeedsYou: Bool
    
    init(
        openWindowOnStart: Bool = true,
        notifyOnFinish: Bool = true,
        notifyOnNeedsYou: Bool = true
    ) {
        self.openWindowOnStart = openWindowOnStart
        self.notifyOnFinish = notifyOnFinish
        self.notifyOnNeedsYou = notifyOnNeedsYou
    }
    
    func didAppear() {}
    func didDisappear() {}
    func didToggleOpenWindowOnStart(_ isOn: Bool) { openWindowOnStart = isOn }
    func didToggleNotifyOnFinish(_ isOn: Bool) { notifyOnFinish = isOn }
    func didToggleNotifyOnNeedsYou(_ isOn: Bool) { notifyOnNeedsYou = isOn }
}

#endif
