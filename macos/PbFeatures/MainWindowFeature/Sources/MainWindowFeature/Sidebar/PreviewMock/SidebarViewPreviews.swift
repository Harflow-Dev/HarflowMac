import MonitorCore
import PbCommon
import PbRepository
import PbUI
import SwiftUI

// MARK: - SidebarViewPreviews

#if DEBUG
#Preview("Default - light") {
    SidebarView(SidebarViewModelMock())
        .frame(width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
        .preferredColorScheme(.light)
}

#Preview("Default - dark") {
    SidebarView(SidebarViewModelMock())
        .frame(width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
        .preferredColorScheme(.dark)
}

#Preview("Install banner - light") {
    SidebarView(SidebarViewModelMock(installBannerModel: installBannerPreviewModel()))
        .frame(width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
        .preferredColorScheme(.light)
}

#Preview("Install banner - dark") {
    SidebarView(SidebarViewModelMock(installBannerModel: installBannerPreviewModel()))
        .frame(width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
        .preferredColorScheme(.dark)
}

#Preview("Loading - light") {
    SidebarView(SidebarViewModelMock(sections: [], showsLoadingSkeleton: true))
        .frame(width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
        .preferredColorScheme(.light)
}

#Preview("Loading - dark") {
    SidebarView(SidebarViewModelMock(sections: [], showsLoadingSkeleton: true))
        .frame(width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
        .preferredColorScheme(.dark)
}

#Preview("Empty, disconnected - light") {
    SidebarView(SidebarViewModelMock(
        sections: [], emptyStateMessage: "No claude tasks yet.", isConnected: false, selectedBackend: "claude"
    ))
    .frame(width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.sidebarCompactPreviewHeight)
    .preferredColorScheme(.light)
}

#Preview("Empty, disconnected - dark") {
    SidebarView(SidebarViewModelMock(
        sections: [], emptyStateMessage: "No claude tasks yet.", isConnected: false, selectedBackend: "claude"
    ))
    .frame(width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.sidebarCompactPreviewHeight)
    .preferredColorScheme(.dark)
}

/// A three-level tree, expanded — Monitor piece 4.
#Preview("Tree - expanded - light") {
    SidebarView(SidebarViewModelMock(sections: [SidebarSection(bucket: .earlier, items: threeLevelTreeRows(collapsed: false))]))
        .frame(width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
        .preferredColorScheme(.light)
}

#Preview("Tree - expanded - dark") {
    SidebarView(SidebarViewModelMock(sections: [SidebarSection(bucket: .earlier, items: threeLevelTreeRows(collapsed: false))]))
        .frame(width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
        .preferredColorScheme(.dark)
}

/// The same tree with the root collapsed: descendants hidden, meta line shows the subtree summary.
#Preview("Tree - collapsed - light") {
    SidebarView(SidebarViewModelMock(sections: [SidebarSection(bucket: .earlier, items: threeLevelTreeRows(collapsed: true))]))
        .frame(width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
        .preferredColorScheme(.light)
}

#Preview("Tree - collapsed - dark") {
    SidebarView(SidebarViewModelMock(sections: [SidebarSection(bucket: .earlier, items: threeLevelTreeRows(collapsed: true))]))
        .frame(width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
        .preferredColorScheme(.dark)
}

/// History with more pages behind it: the manual Load older controls, both sources.
#Preview("History has more - light") {
    SidebarView(SidebarViewModelMock(
        sections: [],
        emptyStateMessage: "No claude tasks yet.",
        taskHistoryState: historyState(hasMore: true),
        workflowHistoryState: historyState(hasMore: true)
    ))
    .frame(width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
    .preferredColorScheme(.light)
}

#Preview("History has more - dark") {
    SidebarView(SidebarViewModelMock(
        sections: [],
        emptyStateMessage: "No claude tasks yet.",
        taskHistoryState: historyState(hasMore: true),
        workflowHistoryState: historyState(hasMore: true)
    ))
    .frame(width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
    .preferredColorScheme(.dark)
}

/// History in flight and after a failure: the loading indicator and the error with its Retry.
#Preview("History loading and error - light") {
    SidebarView(SidebarViewModelMock(
        sections: [],
        emptyStateMessage: "No claude tasks yet.",
        taskHistoryState: historyState(isLoading: true),
        workflowHistoryState: historyState(error: .timedOut(tool: "polybridge-ctl", seconds: 30))
    ))
    .frame(width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
    .preferredColorScheme(.light)
}

#Preview("History loading and error - dark") {
    SidebarView(SidebarViewModelMock(
        sections: [],
        emptyStateMessage: "No claude tasks yet.",
        taskHistoryState: historyState(isLoading: true),
        workflowHistoryState: historyState(error: .timedOut(tool: "polybridge-ctl", seconds: 30))
    ))
    .frame(width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
    .preferredColorScheme(.dark)
}

/// A degraded catalog keeps the same filter choices and says so under the control.
#Preview("Degraded catalog - light") {
    SidebarView(SidebarViewModelMock(
        sections: [],
        emptyStateMessage: "No claude tasks yet.",
        catalogUnavailableNote: "The backend catalog couldn't be read; filters show loaded history only."
    ))
    .frame(width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
    .preferredColorScheme(.light)
}

#Preview("Degraded catalog - dark") {
    SidebarView(SidebarViewModelMock(
        sections: [],
        emptyStateMessage: "No claude tasks yet.",
        catalogUnavailableNote: "The backend catalog couldn't be read; filters show loaded history only."
    ))
    .frame(width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
    .preferredColorScheme(.dark)
}

/// A selected workflow run and its duplicate alias row on the `selectedRow` fill.
#Preview("Selected workflow alias - light") {
    SidebarView(SidebarViewModelMock(
        sections: [SidebarSection(bucket: .today, items: [
            .workflow(TaskRowModel(
                id: "run-1", backend: "workflow", title: "Plan Review Panel", status: .completed, repoName: "Code", ageText: "1d"
            )),
            .workflowShortcut(TaskRowModel(
                id: "run-1", backend: "workflow", title: "Plan Review Panel", status: .completed, repoName: "Code", ageText: "1d"
            ), parentRunID: "run-1")
        ])],
        selection: .workflowRun("run-1")
    ))
    .frame(width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
    .preferredColorScheme(.light)
}

#Preview("Selected workflow alias - dark") {
    SidebarView(SidebarViewModelMock(
        sections: [SidebarSection(bucket: .today, items: [
            .workflow(TaskRowModel(
                id: "run-1", backend: "workflow", title: "Plan Review Panel", status: .completed, repoName: "Code", ageText: "1d"
            )),
            .workflowShortcut(TaskRowModel(
                id: "run-1", backend: "workflow", title: "Plan Review Panel", status: .completed, repoName: "Code", ageText: "1d"
            ), parentRunID: "run-1")
        ])],
        selection: .workflowRun("run-1")
    ))
    .frame(width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
    .preferredColorScheme(.dark)
}

/// The expanded tree with the presentation-only Reduce Motion override — disclosures cross-fade
/// instead of sliding.
#Preview("Tree - Reduce Motion") {
    SidebarView(SidebarViewModelMock(sections: [SidebarSection(bucket: .earlier, items: threeLevelTreeRows(collapsed: false))]))
        .frame(width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
        .preferredColorScheme(.dark)
        .environment(\.pbReduceMotionOverride, true)
}

private func historyState(hasMore: Bool = false, isLoading: Bool = false, error: ToolError? = nil) -> HistoryLoadingState {
    var state = HistoryLoadingState()
    state.hasMore = hasMore
    state.isLoading = isLoading
    state.error = error
    return state
}

private func installBannerPreviewModel() -> InstallBanner.Model {
    InstallBanner.Model(
        title: "polybridge isn't installed",
        detail: "polybridge-ctl wasn't found in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin.",
        primaryTitle: "Install polybridge"
    )
}

private func threeLevelTreeRows(collapsed: Bool) -> [SidebarItem] {
    let root = TaskRowModel(
        id: "root", backend: "claude", title: "Ship the release", status: .completed, repoName: "repo", ageText: "1h",
        indent: 0, subTaskSummary: collapsed ? "3 sub-tasks, 1 running" : "3 sub-tasks", startedAt: nil,
        hasChildren: true, isExpanded: !collapsed, guides: []
    )
    guard !collapsed else { return [.task(root)] }
    return [
        .task(root),
        .task(TaskRowModel(
            id: "childA", backend: "codex", title: "Draft the changelog", status: .running, repoName: "repo", ageText: "",
            indent: 1, subTaskSummary: "1 sub-task", startedAt: .now.addingTimeInterval(-30),
            hasChildren: true, isExpanded: true, guides: [.branch]
        )),
        .task(TaskRowModel(
            id: "grandchild", backend: "vibe", title: "Proofread", status: .completed, repoName: "repo", ageText: "2m",
            indent: 2, startedAt: nil, hasChildren: false, isExpanded: true, guides: [.continuation, .last]
        )),
        .task(TaskRowModel(
            id: "childB", backend: "opencode", title: "Tag the build", status: .completed, repoName: "repo", ageText: "5m",
            indent: 1, startedAt: nil, hasChildren: false, isExpanded: true, guides: [.last]
        ))
    ]
}
#endif
