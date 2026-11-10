//
//  MonitorDestination.swift
//  HfCommon
//
//  The Monitor's navigation destinations (window/navigation seam, decision in the settled plan's
//  "Package graph" section and review finding F7): selecting a task or a parallel group, starting a
//  new session, and opening the main window. `AppCoordinator` (Phase 5) is the only thing that
//  interprets these; repositories never set the selection (they route through `Routing` instead).
//

import Foundation

/// A navigation destination inside the Monitor's coordinator tree.
public enum MonitorDestination: PathDestination, Hashable, Sendable {
    /// Select a task by ID in the sidebar/detail split.
    case task(String)
    /// Select a Parallel run by its group name.
    case group(String)
    /// Open retained finished-work Statistics.
    case statistics
    /// Open read-only resource inventory and phase slot observations.
    case resourceSlots
    /// Open the read-only list of launches that have no task record yet.
    case pendingLaunches
    /// Open Needs you, optionally revealing one request by its stable item id.
    case needsYou(itemID: String?)
    /// Open a saved workflow in the canvas editor.
    case workflow(String)
    /// Browse saved workflows without choosing an execution or creating a definition.
    case workflowLibrary
    /// Create a fresh editor for every add action.
    case newWorkflow(UUID)
    /// Open a persisted workflow run from history or the status item.
    case workflowRun(String)
    /// Open the inline new-task composer.
    case newSession
    /// Bring the main window forward.
    case openWindow

    public var pathId: String {
        switch self {
        case .task(let id): "task:\(id)"
        case .group(let name): "group:\(name)"
        case .statistics: "statistics"
        case .resourceSlots: "resourceSlots"
        case .pendingLaunches: "pendingLaunches"
        case .needsYou(let itemID): "needsYou:\(itemID ?? "")"
        case .workflow(let name): "workflow:\(name)"
        case .workflowLibrary: "workflowLibrary"
        case .newWorkflow(let id): "newWorkflow:\(id)"
        case .workflowRun(let id): "workflowRun:\(id)"
        case .newSession: "newSession"
        case .openWindow: "openWindow"
        }
    }
}
