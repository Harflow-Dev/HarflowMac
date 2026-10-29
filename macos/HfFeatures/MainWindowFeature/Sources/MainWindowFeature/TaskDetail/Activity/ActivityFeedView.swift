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

import HfUI
import MonitorCore
import SwiftUI

// MARK: - ActivityFeedView

/// Shared reading, progressive reveal and older-page behavior across activity surfaces.
struct ActivityFeedView: View {
    let rows: [ActivityRow]
    var activitySnapshot: ActivityFeedSnapshot?
    let start: Date?
    let history: EventHistoryState
    let isLoading: Bool
    var tailValue = ActivityFeedTail()
    var paginationRevision = 0
    var isVisible = true
    var emptyText: String?
    var horizontalPadding: CGFloat = HfRadius.Metrics.zero
    var showsPromptBubble = true
    let state: ParallelColumnUIState
    let onLoadMore: (() -> Bool)?
    var tailPresentation = ActivityFeedTailPresentation.absent
    var onSelectChildTask: ((String) -> Void)?
    var approvalReveal: CallerApprovalReveal?
    var onApprovalResponse: ((String, String) -> Void)?
    var onApprovalToggle: ((String) -> Void)?
    var onApprovalLoadMore: (() -> Void)?
    var onApprovalFocusAcknowledged: ((String, UUID) -> Void)?
    var onApprovalScrollAcknowledged: ((String, UUID) -> Void)?
    var onCancelQueuedMessage: ((String) -> Void)?

    init(rows: [ActivityRow], activitySnapshot: ActivityFeedSnapshot? = nil, start: Date?, history: EventHistoryState, isLoading: Bool,
         tailValue: ActivityFeedTail = ActivityFeedTail(), paginationRevision: Int = 0, isVisible: Bool = true,
         emptyText: String? = nil, horizontalPadding: CGFloat = HfRadius.Metrics.zero, showsPromptBubble: Bool = true,
         state: ParallelColumnUIState, onLoadMore: (() -> Bool)?,
         tailPresentation: ActivityFeedTailPresentation = .absent, onSelectChildTask: ((String) -> Void)? = nil,
         approvalReveal: CallerApprovalReveal? = nil, onApprovalResponse: ((String, String) -> Void)? = nil,
         onApprovalToggle: ((String) -> Void)? = nil, onApprovalLoadMore: (() -> Void)? = nil,
         onApprovalFocusAcknowledged: ((String, UUID) -> Void)? = nil,
         onApprovalScrollAcknowledged: ((String, UUID) -> Void)? = nil,
         onCancelQueuedMessage: ((String) -> Void)? = nil) {
        self.rows = rows
        self.activitySnapshot = activitySnapshot
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
        self.approvalReveal = approvalReveal
        self.onApprovalResponse = onApprovalResponse
        self.onApprovalToggle = onApprovalToggle
        self.onApprovalLoadMore = onApprovalLoadMore
        self.onApprovalFocusAcknowledged = onApprovalFocusAcknowledged
        self.onApprovalScrollAcknowledged = onApprovalScrollAcknowledged
        self.onCancelQueuedMessage = onCancelQueuedMessage
    }

    private var ids: [String] { activitySnapshot?.ids ?? rows.map(\.id) }
    private var shown: [ActivityRow] {
        Array(rows.dropFirst(ActivityFeedWindow.firstIndex(ids: ids, retainedID: state.retainedFirstID)))
    }

    var body: some View {
        ActivityFeedNativeList(model: nativeModel(shownRows: shown), state: state, actions: currentActions)
            .overlay(alignment: .bottomTrailing) {
                if let queuedJumpCount, !state.followLive.isFollowing {
                    QueuedMessageJump(count: queuedJumpCount) {
                        var follow = state.followLive
                        follow.resumeFollowing()
                        state.followLive = follow
                    }
                }
            }
    }

    private var queuedJumpCount: Int? {
        guard case .standard(let standard) = tailPresentation else { return nil }
        let count = standard.workMessages.filter(\.isPinned).count
        return count > 0 ? count : nil
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
            loading: isLoading,
            approvalReveal: approvalReveal,
            activitySnapshot: activitySnapshot
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
        actions.onApprovalResponse = { id, decision in onApprovalResponse?(id, decision) }
        actions.onApprovalToggle = { onApprovalToggle?($0) }
        actions.onApprovalLoadMore = { onApprovalLoadMore?() }
        actions.onApprovalFocusAcknowledged = { onApprovalFocusAcknowledged?($0, $1) }
        actions.onApprovalScrollAcknowledged = { onApprovalScrollAcknowledged?($0, $1) }
        actions.onCancelQueuedMessage = { onCancelQueuedMessage?($0) }
        return actions
    }
}
