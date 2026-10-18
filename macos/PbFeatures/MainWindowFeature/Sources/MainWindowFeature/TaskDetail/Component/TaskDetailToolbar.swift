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
        // TaskStatusLabel reads exactly these fields (the settled branch reads the recorded
        // duration and the observed exit through `TaskSettledDuration`); usage, summary and event
        // metadata stay outside.
        let statusKeys: Set = ["task_id", "status", "started_at", "duration_seconds", "exit_code", "taken_over"]
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
.frame(width: PbRadius.Metrics.zero, height: PbRadius.Metrics.zero)
            .toolbar { toolbarContent }
    }

    /// One SDK glass capsule behind takeover/more/inspector (§3 Liquid Glass), with the status
    /// badge kept visually separate: its own item with the shared background hidden and a fixed
    /// spacer ahead of the group. All four `ToolbarItem` ids are unchanged; when the task is not
    /// terminal-eligible the takeover item renders nothing, so the group is more+inspector only.
    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarSpacer(.flexible)
        ToolbarItem(id: "task-detail.status", placement: .primaryAction) { statusLabel }
            .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.fixed)
        ToolbarItem(id: "task-detail.takeover", placement: .primaryAction) { takeoverButton }
        ToolbarItem(id: "task-detail.more", placement: .primaryAction) {
            Menu { menuItems } label: { Label("More actions", systemImage: "ellipsis") }
                .menuIndicator(.hidden)
.help("More actions")
        }
        ToolbarItem(id: "task-detail.inspector", placement: .primaryAction) { inspectorToggle }
    }

    private var statusLabel: some View {
        HStack(spacing: PbRadius.Metrics.spacing8) {
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

#if DEBUG
@MainActor
private func toolbarPreview(viewModel: TaskDetailViewModelMock, showsInspector: Bool = false) -> some View {
    let task = viewModel.task ?? TaskDetailViewModelMock.sampleTask()
    return NavigationStack {
        Text("Activity")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                TaskDetailToolbar(
                    snapshot: TaskDetailToolbarSnapshot(viewModel, task: task, showsInspector: showsInspector),
                    actions: TaskDetailToolbarActions(
                        takeover: viewModel.didTapTakeover, cancel: viewModel.didTapCancel,
                        copyResumeCommand: viewModel.didTapCopyResumeCommand, openTask: viewModel.didTapTask,
                        showRawEvents: {}, toggleInspector: {}
                    )
                ).equatable()
            }
    }
    .frame(width: PbRadius.Metrics.toolbarPreviewWidth, height: PbRadius.Metrics.toolbarPreviewHeight)
}

#Preview("Toolbar, running - light") {
    toolbarPreview(viewModel: TaskDetailViewModelMock()).preferredColorScheme(.light)
}

#Preview("Toolbar, running - dark") {
    toolbarPreview(viewModel: TaskDetailViewModelMock()).preferredColorScheme(.dark)
}

#Preview("Toolbar, finished with inspector shown - light") {
    toolbarPreview(viewModel: TaskDetailViewModelMock.finished(), showsInspector: true).preferredColorScheme(.light)
}

#Preview("Toolbar, finished with inspector shown - dark") {
    toolbarPreview(viewModel: TaskDetailViewModelMock.finished(), showsInspector: true).preferredColorScheme(.dark)
}

@MainActor
private func noTerminalPreview() -> some View {
    let mock = TaskDetailViewModelMock()
    var raw = mock.task!.raw
    raw["execution_kind"] = .string("native_subagent")
    mock.task = TaskInfo(.object(raw))
    mock.canTakeover = false
    return toolbarPreview(viewModel: mock)
}

#Preview("Toolbar, terminal unavailable - light") { noTerminalPreview().preferredColorScheme(.light) }
#Preview("Toolbar, terminal unavailable - dark") { noTerminalPreview().preferredColorScheme(.dark) }
#endif
