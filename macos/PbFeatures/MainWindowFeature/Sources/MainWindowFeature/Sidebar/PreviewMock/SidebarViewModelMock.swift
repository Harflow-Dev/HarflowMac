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
    
    var sections: [SidebarSection]
    var savedWorkflows: [WorkflowRecord] = []
    var listErrorMessage: String?
    var emptyStateMessage: String?
    var showsLoadingSkeleton: Bool
    var isConnected: Bool
    var connectionLine: String
    var backendTabs: [BackendTab]
    var selectedBackend: String
    var catalogUnavailableNote: String?
    var searchQuery: String
    var selection: MonitorDestination?
    var installBannerModel: InstallBanner.Model?

    init(
        sections: [SidebarSection] = SidebarViewModelMock.defaultSections,
        listErrorMessage: String? = nil,
        emptyStateMessage: String? = nil,
        showsLoadingSkeleton: Bool = false,
        isConnected: Bool = true,
        connectionLine: String = "connected · polybridge-ctl",
        backendTabs: [BackendTab] = [.all, BackendTab(id: "claude", isNotFound: false), BackendTab(id: "codex", isNotFound: false)],
        selectedBackend: String = "all",
        catalogUnavailableNote: String? = nil,
        searchQuery: String = "",
        selection: MonitorDestination? = nil,
        installBannerModel: InstallBanner.Model? = nil
    ) {
        self.sections = sections
        self.listErrorMessage = listErrorMessage
        self.emptyStateMessage = emptyStateMessage
        self.showsLoadingSkeleton = showsLoadingSkeleton
        self.isConnected = isConnected
        self.connectionLine = connectionLine
        self.backendTabs = backendTabs
        self.selectedBackend = selectedBackend
        self.catalogUnavailableNote = catalogUnavailableNote
        self.searchQuery = searchQuery
        self.selection = selection
        self.installBannerModel = installBannerModel
    }

    /// A Running tree (expanded, with a running child), a parallel run and finished Today/Earlier rows.
    static var defaultSections: [SidebarSection] {
        let groupTasks = [
            TaskInfo(.object(["task_id": .string("g1"), "backend": .string("claude"), "status": .string("running"), "group": .string("review-bot")]))!,
            TaskInfo(.object(["task_id": .string("g2"), "backend": .string("codex"), "status": .string("completed"), "group": .string("review-bot")]))!
        ]
        return [
            SidebarSection(bucket: .running, items: [
                .task(TaskRowModel(
                    id: "abc123", backend: "claude", title: "Fix the login bug", status: .running, repoName: "repo",
                    ageText: "", indent: 0, subTaskSummary: "1 sub-task",
                    startedAt: .now.addingTimeInterval(-42), hasChildren: true, isExpanded: true, guides: []
                )),
                .task(TaskRowModel(
                    id: "abc123-child", backend: "codex", title: "Write the migration", status: .running, repoName: "repo",
                    ageText: "", indent: 1, startedAt: .now.addingTimeInterval(-10),
                    hasChildren: false, isExpanded: true, guides: [.last]
                )),
                .group(Lineage.sections(groupTasks).parallel[0])
            ]),
            SidebarSection(bucket: .today, items: [
                .task(TaskRowModel(
                    id: "def456", backend: "codex", title: "Refactor the parser", status: .completed, repoName: "repo",
                    ageText: "3h", indent: 0, startedAt: nil
                ))
            ]),
            SidebarSection(bucket: .earlier, items: [
                .task(TaskRowModel(
                    id: "ghi789", backend: "vibe", title: "Bump dependencies", status: .failed, repoName: "app",
                    ageText: "2d", indent: 0, startedAt: nil
                ))
            ])
        ]
    }

    func didAppear() {}
    func didDisappear() {}
    func didChangeSearchQuery(_ text: String) { searchQuery = text }
    func didSelectBackendFilter(_ backend: String) { selectedBackend = backend }
    func didSelect(_ destination: MonitorDestination?) { selection = destination }
    func didTapNewSession() {}
    func didTapInstallBannerPrimary() {}
    func didTapInstallBannerSecondary() {}
    func didTapInstallBannerDismiss() {}
    func didToggleExpansion(taskID: String) {}
    func didPressMoveCommand(_ direction: MoveCommandDirection) {}
}

#endif
