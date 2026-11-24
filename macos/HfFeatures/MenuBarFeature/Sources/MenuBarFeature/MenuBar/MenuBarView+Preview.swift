//
//  MenuBarView+Preview.swift
//  MenuBarFeature
//

import AppKit
import HfCommon
import HfRepository
import HfUI
import MonitorCore
import SwiftUI

#if DEBUG

// MARK: - MenuBarPreviewModel

/// Preview-only fixture covering the states the shared `MenuBarViewModelMock` cannot express
/// (workflow rows/counts, loading). Every value is explicitly dummy preview data — no production
/// counts or copy derive from it.
@MainActor
private final class MenuBarPreviewModel: MenuBarViewModel {
    var runningRows: [MenuBarRunningRowModel] = []
    var recentGroups: [ParallelGroup] = []
    var recentTasks: [TaskRowModel] = []
    var isConnected = true
    var connectionLine = "connected · harflow-ctl"
    var runningCount = 0
    var canStartNewSession = true
    var taskCountsLoading = false
    var workflowCountsLoading = false
    var workflowRows: [WorkflowMenuBarRow] = []
    var workflowActiveCount = 0
    var workflowAttentionCount = 0
    var workflowStatusError: String?
    var headerSubline = "harflow connected"
    var runtimeCard: MenuBarRuntimeCard?
    var refreshNote: MenuBarRefreshNote?

    static var workflowsAndAttention: MenuBarPreviewModel {
        let model = MenuBarPreviewModel()
        model.runningRows = [
            MenuBarRunningRowModel(
                id: "p1", backend: "claude", title: "Fix the login bug", repoName: "harflow",
                startedAt: .now.addingTimeInterval(-42), durationSeconds: nil,
                activityLine: "swift test --filter LoginTests", activityIsMonospaced: true
            )
        ]
        model.runningCount = 1
        model.workflowRows = [
            WorkflowMenuBarRow([
                "workflow_run_id": .string("w1"), "name": .string("code-review"),
                "status": .string("needs_attention"), "attention_reason": .string("Implementation reached its attempt limit.")
            ]),
            WorkflowMenuBarRow([
                "workflow_run_id": .string("w2"), "name": .string("release-checklist"), "status": .string("running")
            ])
        ].compactMap(\.self)
        model.workflowActiveCount = 2
        model.workflowAttentionCount = 1
        model.recentTasks = [
            TaskRowModel(id: "t1", backend: "codex", title: "Draft release notes", status: .completed, repoName: "harflow", ageText: "3h")
        ]
        return model
    }

    static var loading: MenuBarPreviewModel {
        let model = MenuBarPreviewModel()
        model.taskCountsLoading = true
        model.workflowCountsLoading = true
        return model
    }

    static var refreshNoteShown: MenuBarPreviewModel {
        let model = MenuBarPreviewModel()
        model.isConnected = false
        model.refreshNote = MenuBarRefreshNote(message: "harflow-ctl task-list-page exited 1 without a JSON answer.")
        return model
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
    func didTapRetryRefresh() {}
    func didEditAnswer(_: String, text _: String) {}
    func didSubmitAnswer(_: String) {}
}

private func needsYouRows(_ count: Int) -> [MenuBarNeedsYouSection.Row] {
    var question = MenuBarNeedsYouSection.Row(id: "a", kindLabel: "Question", title: "Release checklist", subtitle: "Ended · Original caller")
    question.item = NeedsYouItem(
        id: "a", kind: .question, runTitle: "Release checklist", text: "Ship the release today?",
        ownership: .init(owner: "caller", callerEnded: true, engineNote: "", handover: nil), startedBy: "Original caller"
    )
    question.question = MenuBarQuestionState(draft: "Yes, ship it.")
    return [
        question,
        .init(id: "b", kindLabel: "Approval", title: "Migrate billing exports", subtitle: "Ended · Original caller"),
        .init(id: "c", kindLabel: "Recovery", title: "Audit lockfile", subtitle: "Mac app")
    ]
.prefix(count)
.map(\.self)
}

#Preview("Menu bar Needs you populated - light") {
    MenuBarView(MenuBarViewModelMock(needsYou: .init(count: 6, rows: needsYouRows(3)))).preferredColorScheme(.light)
}

#Preview("Menu bar Needs you populated - dark") {
    MenuBarView(MenuBarViewModelMock(needsYou: .init(count: 6, rows: needsYouRows(3)))).preferredColorScheme(.dark)
}

#Preview("Menu bar Needs you few") {
    MenuBarView(MenuBarViewModelMock(needsYou: .init(count: 2, rows: needsYouRows(2))))
}

#Preview("Menu bar Needs you empty") {
    MenuBarView(MenuBarViewModelMock(needsYou: .init(count: 0, rows: [])))
}

#Preview("Menu bar Needs you older engine") {
    MenuBarView(MenuBarViewModelMock(needsYou: .init(count: 0, rows: [], olderEngine: true)))
}

#Preview("Menu bar - light") {
    MenuBarView(MenuBarViewModelMock.busy).preferredColorScheme(.light)
}

#Preview("Menu bar - dark") {
    MenuBarView(MenuBarViewModelMock.busy).preferredColorScheme(.dark)
}

#Preview("Menu bar empty - light") {
    MenuBarView(MenuBarViewModelMock(runningRows: [], recentTasks: [], runningCount: 0)).preferredColorScheme(.light)
}

#Preview("Menu bar empty - dark") {
    MenuBarView(MenuBarViewModelMock(runningRows: [], recentTasks: [], runningCount: 0)).preferredColorScheme(.dark)
}

#Preview("Menu bar workflows and attention - light") {
    MenuBarView(MenuBarPreviewModel.workflowsAndAttention).preferredColorScheme(.light)
}

#Preview("Menu bar workflows and attention - dark") {
    MenuBarView(MenuBarPreviewModel.workflowsAndAttention).preferredColorScheme(.dark)
}

#Preview("Menu bar loading - light") {
    MenuBarView(MenuBarPreviewModel.loading).preferredColorScheme(.light)
}

#Preview("Menu bar loading - dark") {
    MenuBarView(MenuBarPreviewModel.loading).preferredColorScheme(.dark)
}

#Preview("Menu bar refresh note - light") {
    MenuBarView(MenuBarPreviewModel.refreshNoteShown).preferredColorScheme(.light)
}

#Preview("Menu bar refresh note - dark") {
    MenuBarView(MenuBarPreviewModel.refreshNoteShown).preferredColorScheme(.dark)
}

#Preview("Menu bar runtime setup required - light") {
    MenuBarView(MenuBarViewModelMock.runtimeNotReady(.setupRequired)).preferredColorScheme(.light)
}

#Preview("Menu bar runtime preparing - dark") {
    MenuBarView(MenuBarViewModelMock.runtimeNotReady(.preparing)).preferredColorScheme(.dark)
}

#Preview("Menu bar runtime failed - light") {
    MenuBarView(MenuBarViewModelMock.runtimeNotReady(.failed(message: "Package verification failed. No replacement was activated.")))
        .preferredColorScheme(.light)
}

#Preview("Menu bar runtime failed - dark") {
    MenuBarView(MenuBarViewModelMock.runtimeNotReady(.failed(message: "Package verification failed. No replacement was activated.")))
        .preferredColorScheme(.dark)
}

/// The popover content as the production scene hosts it: on a native material, not a fabricated
/// flat glass colour, so the user-approved `primaryText` ink can be checked on glass in both
/// appearances. The material here is preview-only — the real MenuBarExtra window paints it.
#Preview("Menu bar on material - light") {
    MenuBarView(MenuBarViewModelMock.busy)
        .preferredColorScheme(.light)
        .background(.ultraThinMaterial)
}

#Preview("Menu bar on material - dark") {
    MenuBarView(MenuBarViewModelMock.busy)
        .preferredColorScheme(.dark)
        .background(.ultraThinMaterial)
}
#endif
