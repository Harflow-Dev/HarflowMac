//
//  MonitorDestination.swift
//  PbCommon
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
    /// Open the New Session sheet.
    case newSession
    /// Bring the main window forward.
    case openWindow

    public var pathId: String {
        switch self {
        case .task(let id): "task:\(id)"
        case .group(let name): "group:\(name)"
        case .newSession: "newSession"
        case .openWindow: "openWindow"
        }
    }
}
