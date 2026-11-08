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

// MARK: - Previews

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
