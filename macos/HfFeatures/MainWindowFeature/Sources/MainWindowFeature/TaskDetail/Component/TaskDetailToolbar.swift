import HfUI
import MonitorCore
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
    let parentTitle: String?
    let repoPath: String?
    let showsInspector: Bool
    /// Whether the inspector item is the standalone right pane ("right pane" wording) or the legacy events pane.
    let isRightPane: Bool
    /// The standalone mount's trailing chips; `nil` on the other mounts, which keep the status item instead.
    let chips: TaskTopBarChips?

    @MainActor init(_ viewModel: any TaskDetailViewModel, task: TaskInfo, showsInspector: Bool, isRightPane: Bool = false,
                    chips: TaskTopBarChips? = nil) {
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
        self.parentTitle = isRightPane ? viewModel.ancestorCrumbs.first { $0.id == viewModel.openParentTaskID }?.title : nil
        self.repoPath = isRightPane ? task.repoPath : nil
        self.showsInspector = showsInspector
        self.isRightPane = isRightPane
        self.chips = chips
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
    var copyTaskID: () -> Void = {}
    var openRepository: () -> Void = {}
    var copyRepoPath: () -> Void = {}
    var revealContinuity: () -> Void = {}
    var revealNotices: () -> Void = {}
    var revealAccess: () -> Void = {}
}

// MARK: - TaskDetailToolbarFocus

/// Where a closed reveal returns focus to: the chip it started from. Not part of the toolbar's equality.
struct TaskDetailToolbarFocus {
    let focus: FocusState<TaskPaneController.Origin?>.Binding
    let accessibility: AccessibilityFocusState<TaskPaneController.Origin?>.Binding
}

/// Marks a chip as the focus target of one reveal origin, when the toolbar was given the bindings.
private struct ChipFocusTarget: ViewModifier {
    let focus: TaskDetailToolbarFocus?
    let origin: TaskPaneController.Origin

    @ViewBuilder func body(content: Content) -> some View {
        if let focus {
            content
                .focused(focus.focus, equals: origin)
                .accessibilityFocused(focus.accessibility, equals: origin)
        } else {
            content
        }
    }
}

// MARK: - TaskDetailToolbar

/// Preferences originate inside the equality boundary; activity remains in the parent content.
struct TaskDetailToolbar: View, Equatable {
    let snapshot: TaskDetailToolbarSnapshot
    let actions: TaskDetailToolbarActions
    /// Native regression probe; production leaves this nil. It never participates in equality.
    var onEvaluation: (() -> Void)?
    /// Focus return targets for the chips; never part of equality.
    var chipFocus: TaskDetailToolbarFocus?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.snapshot == rhs.snapshot }

    var body: some View {
        _ = onEvaluation?()
        return Color.clear
.frame(width: HfRadius.Metrics.zero, height: HfRadius.Metrics.zero)
            .toolbar { toolbarContent }
    }

    /// One SDK glass capsule behind more/inspector (§3 Liquid Glass). The standalone mount
    /// publishes its status badge in the window's principal item and puts the chips ahead of the group
    /// (each its own item, shared background hidden, present only while its condition holds); the other
    /// mounts keep the status item behind a fixed spacer and their separate takeover button.
    /// Standalone takeover is offered inside More actions with the same eligibility and help.
    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarSpacer(.flexible)
        if let chips = snapshot.chips {
            if chips.showsContinuity {
                ToolbarItem(id: "task-detail.chip.continuity", placement: .primaryAction) {
                    TaskTopBarChip(icon: "arrow.clockwise", text: chips.isNarrow ? nil : TaskTopBarChips.continuityText,
                                   help: TaskTopBarChips.continuityLabel, action: actions.revealContinuity)
                        .modifier(ChipFocusTarget(focus: chipFocus, origin: .chipContinuity))
                }
                .sharedBackgroundVisibility(.hidden)
            }
            if chips.noticeCount > 0 {
                ToolbarItem(id: "task-detail.chip.notices", placement: .primaryAction) {
                    TaskTopBarChip(icon: "exclamationmark.triangle", text: chips.noticesText, help: chips.noticesLabel,
                                   action: actions.revealNotices)
                        .modifier(ChipFocusTarget(focus: chipFocus, origin: .chipNotices))
                }
                .sharedBackgroundVisibility(.hidden)
            }
            if let access = chips.accessText {
                ToolbarItem(id: "task-detail.chip.access", placement: .primaryAction) {
                    TaskTopBarChip(icon: "shield", text: chips.isNarrow ? nil : access, help: chips.accessLabel,
                                   action: actions.revealAccess)
                        .modifier(ChipFocusTarget(focus: chipFocus, origin: .chipAccess))
                }
                .sharedBackgroundVisibility(.hidden)
            }
        } else {
            ToolbarItem(id: "task-detail.status", placement: .primaryAction) { statusLabel }
                .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed)
        }
        if !snapshot.isRightPane {
            ToolbarItem(id: "task-detail.takeover", placement: .primaryAction) { takeoverButton }
        }
        ToolbarItem(id: "task-detail.more", placement: .primaryAction) {
            Menu { menuItems } label: { Label("More actions", systemImage: "ellipsis") }
                .menuIndicator(.hidden)
.help("More actions")
.accessibilityLabel("More actions")
        }
        ToolbarItem(id: "task-detail.inspector", placement: .primaryAction) { inspectorToggle }
    }

    private var statusLabel: some View {
        HStack(spacing: HfRadius.Metrics.spacing8) {
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
        let label = snapshot.isRightPane
            ? (snapshot.showsInspector ? "Hide right pane" : "Show right pane")
            : (snapshot.showsInspector ? "Hide event details" : "Show event details")
        return Button(action: actions.toggleInspector) { Image(systemName: "sidebar.right") }
            .buttonStyle(QuietButtonStyle(isSelected: snapshot.showsInspector))
            .help(label)
.accessibilityLabel(label)
    }

    @ViewBuilder private var menuItems: some View {
        if snapshot.isRightPane {
            standaloneMenuItems
        } else {
            if snapshot.canCancel { Button("Cancel", role: .destructive, action: actions.cancel).disabled(snapshot.isBusy) }
            if snapshot.resumeCommand != nil { Button("Copy resume command", action: actions.copyResumeCommand) }
            if let parentID = snapshot.parentID { Button("Open parent") { actions.openTask(parentID) } }
            Divider()
            Button("Events", action: actions.showRawEvents)
        }
    }

    @ViewBuilder private var standaloneMenuItems: some View {
        if snapshot.canCancel { Button("Stop task…", role: .destructive, action: actions.cancel).disabled(snapshot.isBusy) }
        if snapshot.allowsTerminal {
            Button(snapshot.takeoverLabel, action: actions.takeover)
                .disabled(!snapshot.canTakeover)
                .help(snapshot.takeoverHelp)
        }
        if let parentID = snapshot.parentID {
            Button(action: { actions.openTask(parentID) }) {
                Text("Open parent task")
                if let title = snapshot.parentTitle { Text("Started by \(title)") }
            }
        }
        if snapshot.resumeCommand != nil { Button("Copy resume command", action: actions.copyResumeCommand) }
        Button("Copy task ID", action: actions.copyTaskID)
        if let repoPath = snapshot.repoPath {
            Divider()
            Section(Format.repoName(repoPath)) {
                Button("Open in Finder", action: actions.openRepository)
                Button("Copy path", action: actions.copyRepoPath)
            }
        }
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
    .frame(width: HfRadius.Metrics.toolbarPreviewWidth, height: HfRadius.Metrics.toolbarPreviewHeight)
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
