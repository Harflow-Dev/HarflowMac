import Foundation
import HfUI
import HfUtilities
import MonitorCore
import SwiftUI

// MARK: - ParallelLayout

/// The column-width rule (Monitor piece 12, Design point 3): columns fill the available width rather
/// than a fixed 900pt budget, so there is no empty band on the right when the window is wide — with a
/// 360pt lane floor (HarflowDesign `2934681`, `flex: 1 0 360px`), below which lanes keep their minimum width
/// and the row scrolls horizontally instead of squeezing further. A pure function so it is testable without a SwiftUI rendering
/// harness.
enum ParallelLayout {
    /// The width of the 1 pt separator between columns. A `.lane` row draws it between lanes only (HarflowDesign
    /// `2153ab1`, `gap: 1px`: no rule after the last lane); an `.inspector` column keeps one after itself. It is
    /// subtracted from `availableWidth` before dividing, so the columns plus their separators account for the whole row
    /// rather than overflowing it by a few points.
    static let dividerWidth: CGFloat = 1
    static let minimumColumnWidth: CGFloat = 360
    /// The floating sidebar's outer margin: the sidebar column is 264 pt wide, but the panel is drawn 8 pt in from the
    /// window edge, so AppKit's safe area for the detail column ends at 272 pt where the design's detail column starts
    /// at 264 pt (HarflowDesign `2153ab1`, 736 pt at 1000 pt). While the sidebar is expanded the lane row takes this
    /// margin back, so lane 1 starts under the panel's glass margin exactly as drawn.
    static let floatingSidebarMargin: CGFloat = 8

    /// The leading margin the lane row recovers: the floating sidebar's margin while the sidebar is expanded, otherwise
    /// zero (the collapsed rail is a separate 57 pt column, outside the split view). The single gated value that drives
    /// both the lane row's leading inset and the width the columns divide.
    static func leadingRecovery(sidebarExpanded: Bool) -> CGFloat {
        sidebarExpanded ? floatingSidebarMargin : 0
    }

    /// The width of each of `memberCount` columns inside `availableWidth`. `.lane` columns are separated by one rule
    /// each (`count - 1` in all); an `.inspector` column draws its own after it (`count`), as it always has.
    static func columnWidth(memberCount: Int, availableWidth: CGFloat, chrome: ParallelColumnChrome) -> CGFloat {
        let count = max(1, memberCount)
        let separators = chrome == .lane ? count - 1 : count
        let usableWidth = max(0, availableWidth - CGFloat(separators) * dividerWidth)
        return max(minimumColumnWidth, usableWidth / CGFloat(count))
    }

    /// The width a row of `memberCount` columns of `columnWidth` occupies: a stride per column, less the trailing
    /// separator a `.lane` row does not draw.
    static func documentWidth(memberCount: Int, columnWidth: CGFloat, chrome: ParallelColumnChrome) -> CGFloat {
        CGFloat(memberCount) * (columnWidth + dividerWidth) - trailingTrim(chrome: chrome)
    }

    /// What a row's document is shorter than `memberCount * stride` by.
    static func trailingTrim(chrome: ParallelColumnChrome) -> CGFloat {
        chrome == .lane ? dividerWidth : 0
    }
}

// MARK: - Leading recovery modifier

extension View {
    /// Takes back the floating sidebar's 8 pt outer margin on the leading safe area while the sidebar is expanded, so a
    /// lane row's scroll view carries the design's 264 pt column edge as its content inset and its columns divide the
    /// design's 736 pt at the minimum window. A zero-width leading inset with a negative spacing does it: measured in the
    /// production shell, the system's 272 pt becomes 264 pt, whereas `safeAreaPadding` clamps a negative value and
    /// `ignoresSafeArea` drops the inset altogether. With the sidebar collapsed the spacing is zero and nothing changes.
    func parallelLeadingRecovery() -> some View { modifier(ParallelLeadingRecovery()) }
}

private struct ParallelLeadingRecovery: ViewModifier {
    @Environment(\.isFloatingSidebarExpanded) private var sidebarExpanded

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .leading, spacing: -ParallelLayout.leadingRecovery(sidebarExpanded: sidebarExpanded)) {
            Color.clear.frame(width: 0)
        }
    }
}

// MARK: - ParallelLeaseOrder

enum ParallelLeaseOrder {
    nonisolated static func members(_ conversations: [Conversation]) -> [String] {
        let queues = conversations.map { $0.members.reversed().map(\.taskID) }
        var result: [String] = []
        for depth in 0 ..< (queues.map(\.count).max() ?? 0) {
            for queue in queues where depth < queue.count { result.append(queue[depth]) }
        }
        return result
    }
}

// MARK: - ParallelMembership

enum ParallelMembership {
    @MainActor static func extending(_ conversation: Conversation, states: [String: ParallelColumnUIState]) -> Conversation {
        let retained = states.values.first { state in state.inventoryMembers[conversation.current.taskID] != nil }
        let state = states[conversation.id] ?? retained
        guard state?.inventorySession == conversation.current.sessionID else { return conversation }
        let byID = Dictionary((Array(state?.inventoryMembers.values ?? [:].values) + conversation.members).map { ($0.taskID, $0) },
            uniquingKeysWith: { _, fresh in fresh })
        let inventory = Array(byID.values)
        let members = WorkflowOrchestratorConversation.members(containing: conversation.current.taskID, in: inventory)
            ?? Lineage.conversation(containing: conversation.current.taskID, in: inventory)?.members
        return members.map { Conversation(members: $0) } ?? conversation
    }

    static func conversations(tasks: [TaskInfo], group: [Conversation], workflowTaskIDs: [String]?, focusedTaskIDs: Set<String>?) -> [Conversation] {
        guard let workflowTaskIDs else { return WorkflowOrchestratorConversation.conversations(group.flatMap(\.members)) }
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskID, $0) })
        return WorkflowOrchestratorConversation.conversations(workflowTaskIDs.compactMap { byID[$0] }).filter { conversation in
            focusedTaskIDs.map { focus in conversation.members.contains { focus.contains($0.taskID) } } ?? true
        }
    }
}
