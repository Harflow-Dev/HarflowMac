//
//  ActivityFeedView.swift
//  MainWindowFeature
//
//  Shared reading, progressive reveal and older-page behavior across activity surfaces. The
//  feed is an owned native table (see `ActivityFeedNativeList`): this view keeps the caller
//  surface — the same initializer TaskDetail's timeline pane and Parallel's columns use — and
//  translates its inputs into the native model plus the latest action callbacks. All geometry,
//  live follow, anchor persistence, disclosure and older-page behavior live in the native
//  coordinator's one synchronous transaction per update.
//

import MonitorCore
import PbUI
import SwiftUI

// MARK: - ActivityFeedView

/// Shared reading, progressive reveal and older-page behavior across activity surfaces.
struct ActivityFeedView: View {
    let rows: [ActivityRow]
    let start: Date?
    let history: EventHistoryState
    let isLoading: Bool
    var tailValue = ActivityFeedTail()
    var paginationRevision = 0
    var isVisible = true
    var emptyText: String?
    var horizontalPadding: CGFloat = PbRadius.Metrics.zero
    var showsPromptBubble = true
    let state: ParallelColumnUIState
    let onLoadMore: (() -> Bool)?
    var tailPresentation = ActivityFeedTailPresentation.absent
    var onSelectChildTask: ((String) -> Void)?

    init(rows: [ActivityRow], start: Date?, history: EventHistoryState, isLoading: Bool,
         tailValue: ActivityFeedTail = ActivityFeedTail(), paginationRevision: Int = 0, isVisible: Bool = true,
         emptyText: String? = nil, horizontalPadding: CGFloat = PbRadius.Metrics.zero, showsPromptBubble: Bool = true,
         state: ParallelColumnUIState, onLoadMore: (() -> Bool)?,
         tailPresentation: ActivityFeedTailPresentation = .absent, onSelectChildTask: ((String) -> Void)? = nil) {
        self.rows = rows
        self.start = start
        self.history = history
        self.isLoading = isLoading
        self.tailValue = tailValue
        self.paginationRevision = paginationRevision
        self.isVisible = isVisible
        self.emptyText = emptyText
        self.horizontalPadding = horizontalPadding
        self.showsPromptBubble = showsPromptBubble
        self.state = state
        self.onLoadMore = onLoadMore
        self.tailPresentation = tailPresentation
        self.onSelectChildTask = onSelectChildTask
    }

    private var ids: [String] { rows.map(\.id) }
    private var shown: [ActivityRow] {
        Array(rows.dropFirst(ActivityFeedWindow.firstIndex(ids: ids, retainedID: state.retainedFirstID)))
    }

    var body: some View {
        ActivityFeedNativeList(model: nativeModel(shownRows: shown), state: state, actions: currentActions)
    }

    private func nativeModel(shownRows: [ActivityRow]) -> ActivityFeedNativeModel {
        ActivityFeedNativeModel(
            shownRows: shownRows,
            allRowIDs: ids,
            start: start,
            emptyText: emptyText,
            horizontalPadding: horizontalPadding,
            showsPromptBubble: showsPromptBubble,
            expandedGroups: state.expandedGroups,
            tailPresentation: hasTailContent ? tailPresentation : .absent,
            history: history,
            paginationRevision: paginationRevision,
            visible: isVisible,
            loading: isLoading
        )
    }

    private var hasTailContent: Bool { tailPresentation.isVisible(with: tailValue) }

    private var currentActions: ActivityFeedNativeActions {
        let actions = ActivityFeedNativeActions()
        actions.onLoadMore = onLoadMore
        actions.onDisclosure = { id in
            if state.expandedGroups.insert(id).inserted == false { state.expandedGroups.remove(id) }
        }
        actions.onSelectChildTask = { id in onSelectChildTask?(id) }
        return actions
    }
}
