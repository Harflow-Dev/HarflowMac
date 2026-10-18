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
    var headerSubline: String { isConnected ? "polybridge connected" : connectionLine }
    var installBannerModel: InstallBanner.Model?

    init(
        runningRows: [MenuBarRunningRowModel] = [
            MenuBarRunningRowModel(
                id: "abc123", backend: "claude", title: "Fix the login bug", repoName: "polybridge", startedAt: .now.addingTimeInterval(-42),
                durationSeconds: nil, activityLine: "grep -rn \"login\" .", activityIsMonospaced: true
            )
        ],
        recentGroups: [ParallelGroup] = [],
        recentTasks: [TaskRowModel] = [
            TaskRowModel(id: "def456", backend: "codex", title: "Refactor the parser", status: .completed, repoName: "repo", ageText: "3h")
        ],
        listErrorMessage: String? = nil,
        isConnected: Bool = true,
        connectionLine: String = "connected · polybridge-ctl",
        runningCount: Int = 1,
        installBannerModel: InstallBanner.Model? = nil
    ) {
        self.runningRows = runningRows
        self.recentGroups = recentGroups
        self.recentTasks = recentTasks
        self.listErrorMessage = listErrorMessage
        self.isConnected = isConnected
        self.connectionLine = connectionLine
        self.runningCount = runningCount
        self.installBannerModel = installBannerModel
    }

    /// A populated popover: two running tasks, a parallel group and finished tasks of each outcome.
    static var busy: MenuBarViewModelMock {
        let members = [
            TaskInfo(.object(["task_id": .string("g1"), "backend": .string("claude"), "status": .string("running"), "group": .string("release-notes")]))!,
            TaskInfo(.object(["task_id": .string("g2"), "backend": .string("codex"), "status": .string("completed"), "group": .string("release-notes")]))!,
            TaskInfo(.object(["task_id": .string("g3"), "backend": .string("vibe"), "status": .string("completed"), "group": .string("release-notes")]))!
        ]
        return MenuBarViewModelMock(
            runningRows: [
                MenuBarRunningRowModel(
                    id: "abc123", backend: "claude", title: "Fix the login bug", repoName: "polybridge",
                    startedAt: .now.addingTimeInterval(-42), durationSeconds: nil,
                    activityLine: "grep -rn \"login\" .", activityIsMonospaced: true
                ),
                MenuBarRunningRowModel(
                    id: "def456", backend: "codex", title: "Refactor the parser", repoName: "polybridge",
                    startedAt: .now.addingTimeInterval(-10), durationSeconds: nil,
                    activityLine: "Looking at the tokenizer next.", activityIsMonospaced: false
                )
            ],
            recentGroups: Array(Lineage.sections(members).parallel.prefix(1)),
            recentTasks: [
                TaskRowModel(id: "t1", backend: "codex", title: "Draft release notes", status: .completed, repoName: "polybridge", ageText: "3h"),
                TaskRowModel(id: "t2", backend: "vibe", title: "Bump dependencies", status: .failed, repoName: "app", ageText: "1d"),
                TaskRowModel(id: "t3", backend: "opencode", title: "Try a spike", status: .cancelled, repoName: "app", ageText: "2d")
            ],
            runningCount: 2
        )
    }

    static var installNeeded: MenuBarViewModelMock {
        MenuBarViewModelMock(installBannerModel: .init(
            title: "polybridge isn't installed",
            detail: "polybridge-ctl wasn't found in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin.",
            primaryTitle: "Install polybridge"
        ))
    }

    func didAppear() {}
    func didDisappear() {}
    func didAppearRunningRow(_: String) {}
    func didDisappearRunningRow(_: String) {}
    func didSelectRunningTask(_: String) {}
    func didSelectRecentTask(_: String) {}
    func didSelectGroup(_: String) {}
    func didTapOpenMonitor() {}
    func didTapNewSession() {}
    func didCaptureWindowOpener(_: @escaping () -> Void) {}
    func didTapInstallBannerPrimary() {}
    func didTapInstallBannerSecondary() {}
    func didTapInstallBannerDismiss() {}
}

#endif
