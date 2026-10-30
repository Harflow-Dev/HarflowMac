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
    
    var runtimeStatus = "Harflow runtime is ready."
    var runtimeCanRetry = false
    func didTapRetryRuntime() {}

    var directoryField: String
    var searchedDirectoriesText: String
    var ctlResolution: ToolResolution
    var setupResolution: ToolResolution
    var openWindowOnStart: Bool
    var notifyOnFinish: Bool
    var notifyOnNeedsYou: Bool
    
    init(
        directoryField: String = "",
        searchedDirectoriesText: String = "~/.local/bin, /opt/homebrew/bin, /usr/local/bin",
        ctlResolution: ToolResolution = .found(path: "/opt/homebrew/bin/harflow-ctl"),
        setupResolution: ToolResolution = .notFound,
        openWindowOnStart: Bool = true,
        notifyOnFinish: Bool = true,
        notifyOnNeedsYou: Bool = true
    ) {
        self.directoryField = directoryField
        self.searchedDirectoriesText = searchedDirectoriesText
        self.ctlResolution = ctlResolution
        self.setupResolution = setupResolution
        self.openWindowOnStart = openWindowOnStart
        self.notifyOnFinish = notifyOnFinish
        self.notifyOnNeedsYou = notifyOnNeedsYou
    }
    
    func didAppear() {}
    func didDisappear() {}
    func didChangeDirectoryField(_ text: String) { directoryField = text }
    func didTapApply() {}
    func didTapSearchAgain() { directoryField = "" }
    func didToggleOpenWindowOnStart(_ isOn: Bool) { openWindowOnStart = isOn }
    func didToggleNotifyOnFinish(_ isOn: Bool) { notifyOnFinish = isOn }
    func didToggleNotifyOnNeedsYou(_ isOn: Bool) { notifyOnNeedsYou = isOn }
}

#endif
