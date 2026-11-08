//
//  TaskDetailChrome.swift
//  MainWindowFeature
//
//  How a `TaskDetailView` is mounted, and what the standalone mount needs to remember its side pane.
//

import Foundation

// MARK: - TaskDetailChrome

/// The mount a `TaskDetailView` is placed in. It decides which chrome the view draws around the activity.
enum TaskDetailChrome: Equatable, Sendable {
    /// The window's own task selection: the adaptive right pane with Artifacts and Events tabs.
    case standalone
    /// The Group presentation's task pane, and the default for callers that do not opt in: the always-mounted
    /// 320 point pane with the window toolbar.
    case group
    /// The workflow builder's inline row: no window toolbar, the 280 point pane.
    case embedded
}

// MARK: - TaskPaneBinding

/// Where the standalone mount keeps its per-conversation pane choices: the window's store and the conversation
/// id the coordinator keys its `.id(...)` reset by.
struct TaskPaneBinding {
    let store: TaskPaneStateStore
    let conversationID: String
}

// MARK: - TaskPaneHolder

/// Builds the pane controller (and, without a binding, its private store) on first use, so the group and embedded
/// mounts, which never touch the pane, allocate neither.
@MainActor
final class TaskPaneHolder {
    private let make: () -> TaskPaneController
    private var built: TaskPaneController?

    init(make: @escaping () -> TaskPaneController) { self.make = make }

    /// The controller, created on the first read.
    var controller: TaskPaneController {
        if let built { return built }
        let controller = make()
        built = controller
        return controller
    }
}
