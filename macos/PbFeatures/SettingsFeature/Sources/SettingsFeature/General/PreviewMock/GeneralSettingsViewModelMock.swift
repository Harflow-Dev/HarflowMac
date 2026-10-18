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
    
    var directoryField: String
    var searchedDirectoriesText: String
    var ctlResolution: ToolResolution
    var setupResolution: ToolResolution
    var openWindowOnStart: Bool
    var notifyOnFinish: Bool
    
    init(
        directoryField: String = "",
        searchedDirectoriesText: String = "~/.local/bin, /opt/homebrew/bin, /usr/local/bin",
        ctlResolution: ToolResolution = .found(path: "/opt/homebrew/bin/polybridge-ctl"),
        setupResolution: ToolResolution = .notFound,
        openWindowOnStart: Bool = true,
        notifyOnFinish: Bool = true
    ) {
        self.directoryField = directoryField
        self.searchedDirectoriesText = searchedDirectoriesText
        self.ctlResolution = ctlResolution
        self.setupResolution = setupResolution
        self.openWindowOnStart = openWindowOnStart
        self.notifyOnFinish = notifyOnFinish
    }
    
    func didAppear() {}
    func didDisappear() {}
    func didChangeDirectoryField(_ text: String) { directoryField = text }
    func didTapApply() {}
    func didTapSearchAgain() { directoryField = "" }
    func didToggleOpenWindowOnStart(_ isOn: Bool) { openWindowOnStart = isOn }
    func didToggleNotifyOnFinish(_ isOn: Bool) { notifyOnFinish = isOn }
}

#endif
