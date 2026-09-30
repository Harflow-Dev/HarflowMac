//
//  SidebarSection.swift
//  MainWindowFeature
//

import MonitorCore
import PbUI

// MARK: - SidebarItem

/// One selectable entry in a sidebar section: a task row (a root tree's flattened rows, sub-tasks
/// included) or a parallel-run group row. The list tags stay `.task(id)` / `.group(name)`.
enum SidebarItem: Identifiable, Equatable {
    case task(TaskRowModel)
    case group(ParallelGroup)

    var id: String {
        switch self {
        case .task(let row): "task:\(row.id)"
        case .group(let group): group.id
        }
    }
}

// MARK: - SidebarSection

/// A titled bucket of the sidebar list (settled plan D10): Running, Today or Earlier.
struct SidebarSection: Identifiable, Equatable {
    enum Bucket: String, CaseIterable {
        case running, today, earlier

        var title: String {
            switch self {
            case .running: "Running"
            case .today: "Today"
            case .earlier: "Earlier"
            }
        }
    }

    let bucket: Bucket
    let items: [SidebarItem]

    var id: String { bucket.rawValue }
    var title: String { bucket.title }
}
