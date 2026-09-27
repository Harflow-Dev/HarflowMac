//
//  SidebarViewModelMock.swift
//  MainWindowFeature
//

#if DEBUG

import Foundation
import MonitorCore
import PbCommon
import PbUI
import SwiftUI

// MARK: - SidebarViewModelMock

/// Preview mock for `SidebarView`.
@MainActor
final class SidebarViewModelMock: SidebarViewModel {
    
    var runningRows: [TaskRowModel]
    var parallelGroups: [ParallelGroup]
    var recentRows: [TaskRowModel]
    var listErrorMessage: String?
    var emptyStateMessage: String?
    var isConnected: Bool
    var connectionLine: String
    var backendTabs: [BackendTab]
    var selectedBackend: String
    var focusedBackendTab: String
    var catalogUnavailableNote: String?
    var searchQuery: String
    var selection: MonitorDestination?
    var installBannerModel: InstallBanner.Model?

    init(
        runningRows: [TaskRowModel] = [
            TaskRowModel(
                id: "abc123", backend: "claude", title: "Fix the login bug", statusLabel: "Running", statusColor: .runningFG,
                ageText: "", indent: 0, metaText: "~/repo · 1 sub-task · write_in_repo", isRunning: true,
                startedAt: .now.addingTimeInterval(-42), hasChildren: true, isExpanded: true, guides: []
            ),
            TaskRowModel(
                id: "abc123-child", backend: "codex", title: "Write the migration", statusLabel: "Running", statusColor: .runningFG,
                ageText: "", indent: 1, metaText: "~/repo", isRunning: true, startedAt: .now.addingTimeInterval(-10),
                hasChildren: false, isExpanded: true, guides: [.last]
            )
        ],
        parallelGroups: [ParallelGroup] = [],
        recentRows: [TaskRowModel] = [
            TaskRowModel(
                id: "def456", backend: "codex", title: "Refactor the parser", statusLabel: "Done", statusColor: .doneGreen,
                ageText: "3h", indent: 0, metaText: "~/repo", isRunning: false, startedAt: nil
            )
        ],
        listErrorMessage: String? = nil,
        emptyStateMessage: String? = nil,
        isConnected: Bool = true,
        connectionLine: String = "connected · polybridge-ctl",
        backendTabs: [BackendTab] = [.all, BackendTab(id: "claude", isNotFound: false), BackendTab(id: "codex", isNotFound: false)],
        selectedBackend: String = "all",
        focusedBackendTab: String = "all",
        catalogUnavailableNote: String? = nil,
        searchQuery: String = "",
        selection: MonitorDestination? = nil,
        installBannerModel: InstallBanner.Model? = nil
    ) {
        self.runningRows = runningRows
        self.parallelGroups = parallelGroups
        self.recentRows = recentRows
        self.listErrorMessage = listErrorMessage
        self.emptyStateMessage = emptyStateMessage
        self.isConnected = isConnected
        self.connectionLine = connectionLine
        self.backendTabs = backendTabs
        self.selectedBackend = selectedBackend
        self.focusedBackendTab = focusedBackendTab
        self.catalogUnavailableNote = catalogUnavailableNote
        self.searchQuery = searchQuery
        self.selection = selection
        self.installBannerModel = installBannerModel
    }

    func didAppear() {}
    func didDisappear() {}
    func didChangeSearchQuery(_ text: String) { searchQuery = text }
    func didSelectBackendFilter(_ backend: String) { selectedBackend = backend; focusedBackendTab = backend }
    func didPressBackendTabArrow(_ direction: MoveCommandDirection) {}
    func didPressBackendTabConfirm() { didSelectBackendFilter(focusedBackendTab) }
    func didSelect(_ destination: MonitorDestination?) { selection = destination }
    func didTapNewSession() {}
    func didTapInstallBannerPrimary() {}
    func didTapInstallBannerSecondary() {}
    func didTapInstallBannerDismiss() {}
    func didToggleExpansion(taskID: String) {}
    func didPressMoveCommand(_ direction: MoveCommandDirection) {}
}

#endif
