//
//  MenuBarViewModelMock.swift
//  MenuBarFeature
//

#if DEBUG

import Foundation
import MonitorCore
import PbUI

// MARK: - MenuBarViewModelMock

/// Preview mock for `MenuBarView`/`MenuBarLabelView`.
@MainActor
final class MenuBarViewModelMock: MenuBarViewModel {
    
    var runningRows: [MenuBarRunningRowModel]
    var recentGroups: [ParallelGroup]
    var recentTasks: [TaskRowModel]
    var listErrorMessage: String?
    var isConnected: Bool
    var connectionLine: String
    var runningCount: Int
    var openWindowOnStart: Bool
    var notifyOnFinish: Bool
    var installBannerModel: InstallBanner.Model?

    init(
        runningRows: [MenuBarRunningRowModel] = [
            MenuBarRunningRowModel(
                id: "abc123", backend: "claude", title: "Fix the login bug", startedAt: .now.addingTimeInterval(-42),
                durationSeconds: nil, activityLine: "grep -rn \"login\" .", activityIsMonospaced: true
            )
        ],
        recentGroups: [ParallelGroup] = [],
        recentTasks: [TaskRowModel] = [
            TaskRowModel(id: "def456", backend: "codex", title: "Refactor the parser", statusLabel: "Done", statusColor: .doneGreen, ageText: "3h")
        ],
        listErrorMessage: String? = nil,
        isConnected: Bool = true,
        connectionLine: String = "connected · polybridge-ctl",
        runningCount: Int = 1,
        openWindowOnStart: Bool = true,
        notifyOnFinish: Bool = true,
        installBannerModel: InstallBanner.Model? = nil
    ) {
        self.runningRows = runningRows
        self.recentGroups = recentGroups
        self.recentTasks = recentTasks
        self.listErrorMessage = listErrorMessage
        self.isConnected = isConnected
        self.connectionLine = connectionLine
        self.runningCount = runningCount
        self.openWindowOnStart = openWindowOnStart
        self.notifyOnFinish = notifyOnFinish
        self.installBannerModel = installBannerModel
    }

    func didAppear() {}
    func didDisappear() {}
    func didAppearRunningRow(_: String) {}
    func didDisappearRunningRow(_: String) {}
    func didSelectRunningTask(_: String) {}
    func didSelectRecentTask(_: String) {}
    func didSelectGroup(_: String) {}
    func didTapOpenMonitor() {}
    func didToggleOpenWindowOnStart(_ isOn: Bool) { openWindowOnStart = isOn }
    func didToggleNotifyOnFinish(_ isOn: Bool) { notifyOnFinish = isOn }
    func didCaptureWindowOpener(_: @escaping () -> Void) {}
    func didTapInstallBannerPrimary() {}
    func didTapInstallBannerSecondary() {}
    func didTapInstallBannerDismiss() {}
}

#endif
