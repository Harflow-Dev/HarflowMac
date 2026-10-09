import Foundation
import MonitorCore
import PbCommon
import PbUI

// MARK: - Sidebar Rows presentation

extension SidebarPresentationBuilder {

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
                title: title(conversation.first.taskID),
                status: current.status,
                repoName: Format.repoName(current.repoPath),
                ageText: Format.age(current.startedAt, now: input.now),
                indent: entry.indent,
                subTaskSummary: subTaskSummary(for: node, isCollapsed: isCollapsed),
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

    /// Expanded: "N sub-tasks". Collapsed (Design point 4): the subtree summary, "N sub-tasks, M
    /// running" with "M running" omitted when nothing underneath is running — a running descendant
    /// still counts even though its own row is hidden. `nil` for a task with no sub-tasks.
    private func subTaskSummary(for node: ConversationNode, isCollapsed: Bool) -> String? {
        guard node.descendantCount > 0 else { return nil }
        return isCollapsed ? collapsedSummary(for: node) : "\(node.descendantCount) sub-task\(node.descendantCount == 1 ? "" : "s")"
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
