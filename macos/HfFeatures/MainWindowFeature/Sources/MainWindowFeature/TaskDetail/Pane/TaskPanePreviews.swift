//
//  TaskPanePreviews.swift
//  MainWindowFeature
//
//  Previews of the standalone task screen with its right pane open, in both appearances: split beside the
//  column (1280 point container) and overlaid on it (800 point container).
//

#if DEBUG

import SwiftUI

// MARK: - Fixtures

@MainActor
private func panePreview(_ mock: TaskDetailViewModelMock, tab: TaskPaneStateStore.Tab, width: CGFloat, scheme: ColorScheme) -> some View {
    let store = TaskPaneStateStore()
    store.setOpenChoice(.open, for: mock.taskID)
    store.setSelectedTab(tab, for: mock.taskID)
    store.setExpandedGroups([.task, .notices, .continuity], for: mock.taskID)
    return NavigationStack {
        TaskDetailView(mock, chrome: .standalone, paneBinding: TaskPaneBinding(store: store, conversationID: mock.taskID),
                       transcriptStyle: .transcript)
    }
    .frame(width: width, height: 700)
    .preferredColorScheme(scheme)
}

@MainActor
private func changesMock(_ presentation: TaskChangesPresentation, count: Int?) -> TaskDetailViewModelMock {
    let mock = TaskDetailViewModelMock.finished()
    mock.changesPresentation = presentation
    mock.changesTabCount = count
    return mock
}

private let sampleDocument: TaskChangesPresentation = {
    let rows = [
        TaskChangesRowModel(id: 0, letter: "M", statusWord: "modified", path: "app/delivery/queue.py", state: nil, stateHelp: nil,
                            additions: 24, deletions: 3, isDimmed: false),
        TaskChangesRowModel(id: 1, letter: "A", statusWord: "added", path: "assets/icon.png", state: "Binary", stateHelp: nil,
                            additions: nil, deletions: nil, isDimmed: false),
        TaskChangesRowModel(id: 2, letter: "M", statusWord: "modified", path: "app/very/long/path/\\xe9.txt", state: "Path cut · no text",
                            stateHelp: nil, additions: nil, deletions: nil, isDimmed: true)
    ]
    let committed = TaskChangesScopeModel(id: TaskChangesScopeID(taskID: "abc12345", repository: 0, scope: "committed_range"),
                                          title: "Committed", count: "3", tag: nil, captions: [], rows: rows)
    let working = TaskChangesScopeModel(id: TaskChangesScopeID(taskID: "abc12345", repository: 0, scope: "working_tree"),
                                        title: "Working tree", count: "0", tag: nil, captions: [TaskChangesPresentationBuilder.noDifferences], rows: [])
    let repository = TaskChangesRepositoryModel(
        id: 0, name: "repo", help: "/Users/example/repo", tag: nil, count: "3", startsOpen: true,
        attribution: "Observed repository differences; not evidence of task authorship.",
        facts: [TaskChangesFact(term: "Base", value: "a4f91c2 · dispatch"), TaskChangesFact(term: "Started dirty", value: "No")],
        notes: [], scopes: [committed, working])
    return .document(TaskChangesDocument(banner: nil, repositories: [repository], caption: nil))
}()

// MARK: - Previews

#Preview("Pane, split, changes - light") {
    panePreview(changesMock(sampleDocument, count: 3), tab: .changes, width: 1280, scheme: .light)
}

#Preview("Pane, split, changes - dark") {
    panePreview(changesMock(sampleDocument, count: 3), tab: .changes, width: 1280, scheme: .dark)
}

#Preview("Pane, overlay, changes loading - light") {
    panePreview(changesMock(.loading, count: nil), tab: .changes, width: 800, scheme: .light)
}

#Preview("Pane, overlay, changes settling - dark") {
    panePreview(changesMock(.settlingCapped, count: nil), tab: .changes, width: 800, scheme: .dark)
}

#Preview("Pane, split, events - light") {
    panePreview(.continuity(notices: ["Checkout is on the default branch."]), tab: .events, width: 1280, scheme: .light)
}

#Preview("Pane, split, events - dark") {
    panePreview(.continuity(notices: ["Checkout is on the default branch."]), tab: .events, width: 1280, scheme: .dark)
}

#Preview("Pane, overlay, events - light") {
    panePreview(.finished(), tab: .events, width: 800, scheme: .light)
}

#Preview("Pane, overlay, events - dark") {
    panePreview(.finished(), tab: .events, width: 800, scheme: .dark)
}

#Preview("Pane, split, artifacts - light") {
    panePreview(.finished(), tab: .artifacts, width: 1280, scheme: .light)
}

#Preview("Pane, split, artifacts - dark") {
    panePreview(.finished(), tab: .artifacts, width: 1280, scheme: .dark)
}

#endif
