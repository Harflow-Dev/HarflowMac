//
//  SidebarSection.swift
//  MainWindowFeature
//

import MonitorCore
import PbCommon
import PbUI

// MARK: - SidebarItem

/// One selectable entry in a sidebar section: a task row (a root tree's flattened rows, sub-tasks
/// included), workflow run, invocation shortcut, or parallel group. Workflow shortcuts and real
/// rows share one navigation destination while retaining independent presentation identities.
enum SidebarItem: Identifiable, Equatable {
    case task(TaskRowModel)
    case group(ParallelGroup)
    case workflow(TaskRowModel)
    case workflowShortcut(TaskRowModel, parentRunID: String)

    var id: String {
        switch self {
        case .task(let row): "task:\(row.id)"
        case .group(let group): group.id
        case .workflow(let row): "workflow:\(row.id)"
        case .workflowShortcut(let row, let parentID): "workflow-shortcut:\(parentID):\(row.id)"
        }
    }

    var destination: MonitorDestination {
        switch self {
        case .task(let row): .task(row.id)
        case .group(let group): .group(group.name)
        case .workflow(let row), .workflowShortcut(let row, _): .workflowRun(row.id)
        }
    }

    func isSelected(_ selection: MonitorDestination?) -> Bool { destination == selection }

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

    /// Keeps outgoing rows in their previous order until their disclosure fade finishes.
    static func retainingRemovedRows(from old: [Self], in new: [Self]) -> [Self] {
        var result = new
        let visibleIDs = Set(new.flatMap(\.items).map(\.id))
        for section in old {
            guard let sectionIndex = result.firstIndex(where: { $0.id == section.id }) else {
                let removed = section.items.filter { !visibleIDs.contains($0.id) }
                if !removed.isEmpty { result.append(Self(bucket: section.bucket, items: removed)) }
                continue
            }
            var items = result[sectionIndex].items
            for (index, item) in section.items.enumerated().reversed() where !visibleIDs.contains(item.id) {
                let nextIDs = Set(section.items.dropFirst(index + 1).map(\.id))
                let insertion = items.firstIndex(where: { nextIDs.contains($0.id) }) ?? items.endIndex
                items.insert(item, at: insertion)
            }
            result[sectionIndex] = Self(bucket: section.bucket, items: items)
        }
        return Bucket.allCases.compactMap { bucket in result.first { $0.bucket == bucket } }
    }
}
