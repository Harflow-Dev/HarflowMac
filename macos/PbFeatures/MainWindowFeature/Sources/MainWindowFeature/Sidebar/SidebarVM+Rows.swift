//
//  SidebarVM+Rows.swift
//  MainWindowFeature
//
//  Split out of SidebarVM.swift purely to keep that file under the swiftlint length budget — same
//  VM, same behaviour. `recompute()` (SidebarVM.swift) calls `flattenedRows(_:forcedExpandedIDs:)`
//  for both `sections.running` and `sections.recent`; the rest of this file supports it. `private`
//  is file-scoped in Swift, so these are plain (internal) methods, same reasoning as
//  `SidebarVM+Retention.swift`'s own cross-file members.
//

import Foundation
import MonitorCore
import PbUI

extension SidebarVM {

    /// Flattens one conversation tree into rows, hiding the descendants of a collapsed node (unless
    /// `forcedExpandedIDs` overrides it for the current filter) — a node's own row is always kept,
    /// only its subtree can be hidden. Status/age/meta come from the conversation's CURRENT member;
    /// title from its FIRST (Design point 2). Row `id` is the conversation id (its first member),
    /// so a click already selects the whole conversation with no separate normalisation needed.
    func flattenedRows(_ root: ConversationNode, forcedExpandedIDs: Set<String>) -> [TaskRowModel] {
        var rows: [TaskRowModel] = []
        var hiddenBelowIndent: Int?
        for entry in root.flattenedWithGuides() {
            if let hiddenBelowIndent, entry.indent > hiddenBelowIndent { continue }
            hiddenBelowIndent = nil

            let node = entry.node
            let conversation = node.conversation
            let current = conversation.current
            let hasChildren = !node.children.isEmpty
            let isCollapsed = collapsedTaskIDs.contains(conversation.id) && !forcedExpandedIDs.contains(conversation.id)
            rows.append(TaskRowModel(
                id: conversation.id,
                backend: current.backend,
                title: useCase.title(conversation.first.taskID),
                statusLabel: current.status.label,
                statusColor: StatusColor.of(current.status),
                ageText: Format.age(current.startedAt),
                indent: entry.indent,
                metaText: metaText(for: node, isCollapsed: isCollapsed),
                isRunning: current.status.isRunning,
                startedAt: current.startedAt,
                durationSeconds: current.durationSeconds,
                hasChildren: hasChildren,
                isExpanded: !isCollapsed,
                guides: entry.guides
            ))
            if hasChildren, isCollapsed { hiddenBelowIndent = entry.indent }
        }
        return rows
    }

    /// Expanded: today's "repo · N sub-tasks · freedom" line. Collapsed (Design point 4): the
    /// subtree summary, "N sub-tasks, M running" with "M running" omitted when nothing underneath
    /// is running — a running descendant still counts even though its own row is hidden.
    private func metaText(for node: ConversationNode, isCollapsed: Bool) -> String {
        let current = node.conversation.current
        var parts = [Format.repo(current.repoPath)]
        if node.descendantCount > 0 {
            parts.append(isCollapsed ? collapsedSummary(for: node) : "\(node.descendantCount) sub-task\(node.descendantCount == 1 ? "" : "s")")
        }
        if let freedom = current.freedom { parts.append(freedom) }
        return parts.joined(separator: " · ")
    }

    private func collapsedSummary(for node: ConversationNode) -> String {
        let base = "\(node.descendantCount) sub-task\(node.descendantCount == 1 ? "" : "s")"
        let running = runningDescendantCount(node)
        return running > 0 ? "\(base), \(running) running" : base
    }

    private func runningDescendantCount(_ node: ConversationNode) -> Int {
        node.children.reduce(0) { $0 + ($1.conversation.current.status.isRunning ? 1 : 0) + runningDescendantCount($1) }
    }
}
