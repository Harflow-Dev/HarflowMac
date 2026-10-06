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
    case workflow(TaskRowModel)

    var id: String {
        switch self {
        case .task(let row): "task:\(row.id)"
        case .group(let group): group.id
        case .workflow(let row): "workflow:\(row.id)"
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
