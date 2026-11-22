import Foundation
import MonitorCore

// MARK: - TaskDetailToolbarHooks

/// The toolbar actions that are the view's own (pane and reveal handling), as opposed to the view model's.
struct TaskDetailToolbarHooks {
    let showRawEvents: () -> Void
    let toggleInspector: () -> Void
    let openRepository: (URL) -> Void
    let revealContinuity: () -> Void
    let revealNotices: () -> Void
    let revealAccess: () -> Void
}

// MARK: - Toolbar actions

extension TaskDetailView {
    /// The only construction site of the toolbar's actions: More → Stop is the view model's `didTapCancel`, and the factory
    /// keeps that binding testable without mounting a window.
    @MainActor
    static func toolbarActions(viewModel: VM, task: TaskInfo, hooks: TaskDetailToolbarHooks) -> TaskDetailToolbarActions {
        TaskDetailToolbarActions(
            takeover: viewModel.didTapTakeover, cancel: viewModel.didTapCancel,
            copyResumeCommand: viewModel.didTapCopyResumeCommand, openTask: viewModel.didTapTask,
            showRawEvents: hooks.showRawEvents,
            toggleInspector: hooks.toggleInspector,
            copyTaskID: viewModel.didTapCopyTaskID,
            openRepository: { hooks.openRepository(URL(fileURLWithPath: task.repoPath, isDirectory: true)) },
            copyRepoPath: viewModel.didTapCopyRepoPath,
            revealContinuity: hooks.revealContinuity, revealNotices: hooks.revealNotices, revealAccess: hooks.revealAccess
        )
    }
}
