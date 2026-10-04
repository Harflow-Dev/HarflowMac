//
//  SidebarVM+Sections.swift
//  MainWindowFeature
//
//  Settled plan D10: whole root trees and parallel-group entries are bucketed into Running / Today /
//  Earlier BEFORE flattening, so a finished root with a running descendant stays in Running and a
//  group sits inline among the tasks. `private` is file-scoped in Swift, hence the internal members.
//

import Foundation
import MonitorCore
import PbUI

// MARK: - SidebarEntry

/// A not-yet-flattened sidebar entry: a whole conversation tree or a parallel group.
enum SidebarEntry {
    case tree(ConversationNode)
    case group(ParallelGroup)
    case workflow(SidebarWorkflowRun)

    var isRunning: Bool {
        switch self {
        case .tree(let node): node.anyRunning
        case .group(let group): group.anyRunning
        case .workflow(let run): run.isActive
        }
    }

    /// A tree's root current-run start; a group's earliest member start.
    var startedAt: Date? {
        switch self {
        case .tree(let node): node.conversation.current.startedAt
        case .group(let group): group.startedAt
        case .workflow(let run): run.startedAt
        }
    }

    var id: String {
        switch self {
        case .tree(let node): "task:\(node.id)"
        case .group(let group): group.id
        case .workflow(let run): "workflow:\(run.id)"
        }
    }
}

extension SidebarVM {

    /// Buckets `trees` and `groups` (D10), orders each bucket newest start first (an entry with no
    /// start time sorts last, ties broken by id), then flattens every entry into items. Empty
    /// buckets are omitted.
    func bucketedSections(trees: [ConversationNode], groups: [ParallelGroup], forcedExpandedIDs: Set<String>) -> [SidebarSection] {
        let entries = trees.map(SidebarEntry.tree) + groups.map(SidebarEntry.group) + filteredWorkflowRuns().map(SidebarEntry.workflow)
        let now = currentDate()
        var buckets: [SidebarSection.Bucket: [SidebarEntry]] = [:]
        for entry in entries {
            buckets[bucket(for: entry, now: now), default: []].append(entry)
        }
        return SidebarSection.Bucket.allCases.compactMap { bucket in
            guard let bucketEntries = buckets[bucket], !bucketEntries.isEmpty else { return nil }
            let ordered = bucketEntries.sorted(by: Self.newestFirst)
            return SidebarSection(bucket: bucket, items: ordered.flatMap { items(for: $0, forcedExpandedIDs: forcedExpandedIDs) })
        }
    }

    private func bucket(for entry: SidebarEntry, now: Date) -> SidebarSection.Bucket {
        if entry.isRunning { return .running }
        guard let startedAt = entry.startedAt, Calendar.current.isDate(startedAt, inSameDayAs: now) else { return .earlier }
        return .today
    }

    private func items(for entry: SidebarEntry, forcedExpandedIDs: Set<String>) -> [SidebarItem] {
        switch entry {
        case .tree(let node): flattenedRows(node, forcedExpandedIDs: forcedExpandedIDs).map(SidebarItem.task)
        case .group(let group):
            [.group(group)] + (group.total > 1 && expandedExecutionParents.contains(group.id) ? executionRows(groupChildren(group.name)) : [])
        case .workflow(let run):
            [.workflow(workflowRow(run))] + (expandedExecutionParents.contains("workflow:\(run.id)") ? executionRows(workflowChildren(run.id)) : [])
        }
    }

    private static func newestFirst(_ lhs: SidebarEntry, _ rhs: SidebarEntry) -> Bool {
        switch (lhs.startedAt, rhs.startedAt) {
        case let (left?, right?) where left != right: left > right
        case (.some, nil): true
        case (nil, .some): false
        default: lhs.id < rhs.id
        }
    }
}
