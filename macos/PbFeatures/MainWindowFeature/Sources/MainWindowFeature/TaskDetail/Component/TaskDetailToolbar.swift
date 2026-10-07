import MonitorCore
import PbUI
import SwiftUI

// MARK: - TaskDetailToolbarSnapshot

/// Only values rendered by standalone window chrome participate in its update boundary.
struct TaskDetailToolbarSnapshot: Equatable, Sendable {
    let ownerID: ObjectIdentifier
    let conversationID: String
    let statusTask: TaskInfo
    let isBusy: Bool
    let allowsTerminal: Bool
    let canTakeover: Bool
    let takeoverLabel: String
    let takeoverHelp: String
    let canCancel: Bool
    let resumeCommand: String?
    let parentID: String?
    let showsInspector: Bool

    @MainActor init(_ viewModel: any TaskDetailViewModel, task: TaskInfo, showsInspector: Bool) {
        self.ownerID = ObjectIdentifier(viewModel)
        self.conversationID = viewModel.taskID
        // TaskStatusLabel reads exactly these fields; usage, summary and event metadata stay outside.
        let statusKeys: Set = ["task_id", "status", "started_at", "duration_seconds", "taken_over"]
        self.statusTask = TaskInfo(.object(task.raw.filter { statusKeys.contains($0.key) })) ?? task
        self.isBusy = viewModel.isBusy
        self.allowsTerminal = WorkflowNodePresentation.allowsTerminal(viewModel.task)
        self.canTakeover = viewModel.canTakeover
        self.takeoverLabel = viewModel.takeoverButtonLabel
        self.takeoverHelp = viewModel.takeoverHelp
        self.canCancel = viewModel.canCancel
        self.resumeCommand = viewModel.resumeCommand
        self.parentID = viewModel.openParentTaskID
        self.showsInspector = showsInspector
    }
}

// MARK: - TaskDetailToolbarActions

struct TaskDetailToolbarActions {
    let takeover: () -> Void
    let cancel: () -> Void
    let copyResumeCommand: () -> Void
    let openTask: (String) -> Void
    let showRawEvents: () -> Void
    let toggleInspector: () -> Void
}

// MARK: - TaskDetailToolbar

/// Preferences originate inside the equality boundary; activity remains in the parent content.
struct TaskDetailToolbar: View, Equatable {
    let snapshot: TaskDetailToolbarSnapshot
    let actions: TaskDetailToolbarActions
    /// Native regression probe; production leaves this nil. It never participates in equality.
    var onEvaluation: (() -> Void)?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.snapshot == rhs.snapshot }

    var body: some View {
        _ = onEvaluation?()
        return Color.clear
.frame(width: 0, height: 0)
            .toolbar { toolbarContent }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
            ToolbarItem(id: "task-detail.status", placement: .primaryAction) { statusLabel }
                .sharedBackgroundVisibility(.hidden)
            ToolbarItem(id: "task-detail.takeover", placement: .primaryAction) { takeoverButton }
                .sharedBackgroundVisibility(.hidden)
            ToolbarItem(id: "task-detail.more", placement: .primaryAction) {
                Menu { menuItems } label: { Label("More actions", systemImage: "ellipsis") }
                    .menuIndicator(.hidden)
.help("More actions")
            }.sharedBackgroundVisibility(.hidden)
            ToolbarItem(id: "task-detail.inspector", placement: .primaryAction) { inspectorToggle }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(id: "task-detail.actions", placement: .primaryAction) {
                HStack(spacing: 10) {
                    statusLabel
                    takeoverButton
                    Menu { menuItems } label: {
                        Image(systemName: "ellipsis.circle").frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
.menuIndicator(.hidden)
.fixedSize()
                    .help("More actions")
.accessibilityLabel("More actions")
                    inspectorToggle
                }.fixedSize()
            }
        }
    }

    private var statusLabel: some View {
        HStack(spacing: 8) {
            TaskStatusLabel(task: snapshot.statusTask).fixedSize()
            if snapshot.isBusy { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder private var takeoverButton: some View {
        if snapshot.allowsTerminal {
            TerminalActionButton(snapshot.takeoverLabel, action: actions.takeover)
                .disabled(!snapshot.canTakeover)
.help(snapshot.takeoverHelp)
        }
    }

    private var inspectorToggle: some View {
        let label = snapshot.showsInspector ? "Hide inspector" : "Show inspector"
        return Button(action: actions.toggleInspector) { Image(systemName: "sidebar.right") }
            .buttonStyle(QuietButtonStyle(isSelected: snapshot.showsInspector))
            .help(label)
.accessibilityLabel(label)
    }

    @ViewBuilder private var menuItems: some View {
        if snapshot.canCancel { Button("Cancel", role: .destructive, action: actions.cancel).disabled(snapshot.isBusy) }
        if snapshot.resumeCommand != nil { Button("Copy resume command", action: actions.copyResumeCommand) }
        if let parentID = snapshot.parentID { Button("Open parent") { actions.openTask(parentID) } }
        Divider()
        Button("Raw events", action: actions.showRawEvents)
    }
}
