//
//  SidebarViewModelMock.swift
//  MainWindowFeature
//

#if DEBUG

import Foundation
import MonitorCore
import PbCommon
import PbUI

// MARK: - SidebarViewModelMock

/// Preview mock for `SidebarView`.
@MainActor
final class SidebarViewModelMock: SidebarViewModel {
    
    var runningRows: [TaskRowModel]
    var parallelGroups: [ParallelGroup]
    var interactiveRows: [InteractiveSessionRowModel]
    var recentRows: [TaskRowModel]
    var listErrorMessage: String?
    var isEmptyState: Bool
    var isConnected: Bool
    var connectionLine: String
    var availableBackends: [String]
    var selectedBackend: String
    var searchQuery: String
    var selection: MonitorDestination?
    
    init(
        runningRows: [TaskRowModel] = [
            TaskRowModel(
                id: "abc123", backend: "claude", title: "Fix the login bug", statusLabel: "Running", statusColor: .runningFG,
                ageText: "", indent: 0, metaText: "~/repo · write_in_repo", hasLiveSession: true, isRunning: true,
                startedAt: .now.addingTimeInterval(-42)
            )
        ],
        parallelGroups: [ParallelGroup] = [],
        interactiveRows: [InteractiveSessionRowModel] = [],
        recentRows: [TaskRowModel] = [
            TaskRowModel(
                id: "def456", backend: "codex", title: "Refactor the parser", statusLabel: "Done", statusColor: .doneGreen,
                ageText: "3h", indent: 0, metaText: "~/repo", hasLiveSession: false, isRunning: false, startedAt: nil
            )
        ],
        listErrorMessage: String? = nil,
        isEmptyState: Bool = false,
        isConnected: Bool = true,
        connectionLine: String = "connected · polybridge-ctl",
        availableBackends: [String] = ["claude", "codex"],
        selectedBackend: String = "all",
        searchQuery: String = "",
        selection: MonitorDestination? = nil
    ) {
        self.runningRows = runningRows
        self.parallelGroups = parallelGroups
        self.interactiveRows = interactiveRows
        self.recentRows = recentRows
        self.listErrorMessage = listErrorMessage
        self.isEmptyState = isEmptyState
        self.isConnected = isConnected
        self.connectionLine = connectionLine
        self.availableBackends = availableBackends
        self.selectedBackend = selectedBackend
        self.searchQuery = searchQuery
        self.selection = selection
    }
    
    func didAppear() {}
    func didDisappear() {}
    func didChangeSearchQuery(_ text: String) { searchQuery = text }
    func didSelectBackendFilter(_ backend: String) { selectedBackend = backend }
    func didSelect(_ destination: MonitorDestination?) { selection = destination }
    func didTapNewSession() {}
}

#endif
