import HfUI
import MonitorCore
import SwiftUI

// MARK: - Inline selected inspector

extension ParallelColumnView {

    // MARK: Inline inspector document

    var inlineInspectorBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            inlineFeed.frame(maxWidth: .infinity, maxHeight: .infinity)
            if !model.hidesInspectorComposer {
                Divider()
                inspectorComposer
                    .padding(.top, 4)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inlineFeed: ActivityFeedView {
        let source = ActivityFeedApprovalEntry.Source.task(model.task.taskID)
        let controller = inlineApprovalController
        var feed = ActivityFeedView(rows: model.activityRows, activitySnapshot: model.activitySnapshot,
            start: model.start, history: model.history, isLoading: model.isLoading,
            tailValue: ActivityFeedTail(liveStep: model.liveStep, pendingMessages: model.pendingMessages),
            paginationRevision: model.paginationRevision, isVisible: model.isVisible, emptyText: model.emptyText,
            horizontalPadding: 16, showsPromptBubble: false, state: state, onLoadMore: model.onLoadMore,
            tailPresentation: .standard(.init(pendingMessages: model.pendingMessages, workMessages: model.workMessages,
                liveStep: model.liveStep.map { .init(text: $0.text, indicator: .threeDots) },
                cancel: model.onCancelMessage == nil ? .hidden : (model.isBusy ? .disabled : .enabled))),
            onSelectChildTask: model.onSelectTask, approvalReveal: controller?.reveal,
            onApprovalScrollAcknowledged: { id, token in controller?.acknowledgeScroll(requestID: id, token: token) },
            onCancelQueuedMessage: model.onCancelMessage)
        feed.callReveal = inspectorDocument.callReveal
        feed.onCallScrollAcknowledged = acknowledgeCallScroll
        feed.leadingContent = inspectorDocument.rows + [.init(scope: model.task.taskID, kind: .taskContext,
            input: .taskContext(inlineContextInput), content: AnyView(inlineTaskContext))]
        feed.approvalSource = source
        feed.composerEdge = inspectorDocument.retainedSteering ? inspectorDocument.composerEdge : !model.hidesInspectorComposer
        feed.followingContent = inspectorDocument.followingContent
        if inspectorDocument.retainedSteering {
            feed.approvalSource = nil
            feed.approvalReveal = nil
            if let reveal = controller?.reveal { feed.scopedApprovalReveals.append(.init(source: source, reveal: reveal)) }
            if let runSource = rootApprovalSource, let reveal = rootApprovalController?.reveal {
                feed.scopedApprovalReveals.append(.init(source: runSource, reveal: reveal))
            }
        }
        if let controller {
            feed.scopedApprovals = controller.cards.map { original in
                var card = original
                card.canRespond = card.canRespond && !controller.isLoading && !controller.isSubmitting && !controller.isResponseQueued
                return ActivityFeedApprovalEntry(source: source, card: card)
            }
            if !controller.cards.isEmpty || controller.error != nil || controller.isLoading
                || controller.nextCursor != nil || controller.acquisitionLimited {
                let status = ActivityFeedSupplementaryRow.ApprovalStatus(loading: controller.isLoading,
                    submitting: controller.isSubmitting || controller.isResponseQueued, hasMore: controller.nextCursor != nil,
                    limited: controller.acquisitionLimited, error: controller.error)
                feed.trailingContent = [.init(scope: model.task.taskID, kind: .approvalStatus,
                                              input: .approval(status), content: AnyView(inlineApprovalStatus(controller)))]
            }
        }
        if inspectorDocument.retainedSteering {
            var content: [ActivityFeedDocumentEntry] = []
            let prelude = ActivityFeedTailPresentation.standard(.init(
                workMessages: model.workMessages.filter { !$0.isPinned },
                liveStep: model.liveStep.map { .init(text: $0.text, indicator: .threeDots) }))
            if model.workMessages.contains(where: { !$0.isPinned }) || model.liveStep != nil {
                content.append(.supplementary(.init(scope: model.task.taskID, kind: .taskActivityTail,
                    input: .activityTail(prelude), content: AnyView(ActivityFeedNativeTailContent(
                        presentation: prelude, actions: ActivityFeedNativeActions(), style: .standard)))))
            }
            content.append(contentsOf: feed.scopedApprovals.map(ActivityFeedDocumentEntry.approval))
            content.append(contentsOf: feed.trailingContent.map(ActivityFeedDocumentEntry.supplementary))
            content.append(contentsOf: feed.followingContent)
            feed.scopedApprovals = []
            feed.trailingContent = []
            feed.followingContent = content
            feed.tailPresentation = .standard(.init(pendingMessages: model.pendingMessages,
                workMessages: model.workMessages.filter(\.isPinned),
                cancel: model.onCancelMessage == nil ? .hidden : (model.isBusy ? .disabled : .enabled)))
        }
        feed.onScopedApprovalResponse = { owner, id, decision in
            approvalController(for: owner)?.submit(decision, requestID: id)
        }
        feed.onScopedApprovalToggle = { owner, id in approvalController(for: owner)?.toggle(id) }
        feed.onScopedApprovalRefresh = { owner in approvalController(for: owner)?.requestRefresh() }
        feed.onScopedApprovalScrollAcknowledged = { owner, id, token in
            approvalController(for: owner)?.acknowledgeScroll(requestID: id, token: token)
        }
        feed.onScopedApprovalFocusAcknowledged = { owner, id, token in
            approvalController(for: owner)?.acknowledgeFocus(requestID: id, token: token)
        }
        return feed
    }

    private var rootApprovalSource: ActivityFeedApprovalEntry.Source? {
        inspectorDocument.retainedSteering ? inspectorDocument.rootApprovalSource : nil
    }

    private func approvalController(for source: ActivityFeedApprovalEntry.Source) -> CallerApprovalController? {
        if source == .task(model.task.taskID) { return inlineApprovalController }
        if source == rootApprovalSource { return rootApprovalController }
        return nil
    }

    private var inlineContextInput: ActivityFeedSupplementaryRow.TaskContextInput {
        .init(showsTitle: model.showsInspectorTitle, title: model.title, subtitle: model.subtitle,
              backend: model.task.backend, status: model.task.raw["status"]?.stringValue,
              startedAt: model.task.startedAt, duration: model.task.durationSeconds, exitCode: model.task.exitCode,
              takenOver: model.task.takenOver, busy: model.isBusy, allowsTerminal: WorkflowNodePresentation.allowsTerminal(model.task),
              hasSession: model.task.sessionID != nil, hasTakeover: model.onTapTakeover != nil,
              hasAdopt: model.onAdoptWindow != nil, notice: model.cachedHistoryNotice, outcome: model.outcomeMessage,
              summary: showsResultCallout ? model.summary : nil, count: model.stepCountText,
              noCalls: model.noToolCallsText, historyFocus: inlineHistoryFocus)
    }

    private var inlineHistoryBoundary: some View {
        WorkflowInspectorHistoryBoundary(text: model.cachedHistoryNotice ?? "Available captured history",
            focusToken: inlineHistoryFocus, onAdopt: model.onAdoptWindow.map { adopt in
                {
                    inlineHistoryFocus = UUID()
                    adopt()
                }
            }, acknowledge: { token in if inlineHistoryFocus == token { inlineHistoryFocus = nil } })
    }

    private var inlineTaskContext: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let message = model.outcomeMessage {
                Text(message)
.font(.hf(.caption))
.foregroundStyle(Color.secondaryText)
                    .accessibilityIdentifier("parallel-column-outcome")
            }
            inlineHistoryBoundary
            if showsResultCallout, let summary = model.summary {
                MarkdownText(text: summary)
.padding(12)
.frame(maxWidth: .infinity, alignment: .leading)
                    .background(resultBackground, in: RoundedRectangle(cornerRadius: HfRadius.card))
                    .accessibilityLabel("Result")
            }
            if let text = model.stepCountText { Text(text).font(.hf(.secondary)).foregroundStyle(Color.secondaryText) }
            if let text = model.noToolCallsText { Text(text).font(.hf(.secondary)).foregroundStyle(Color.tertiaryText) }
        }
    }

    private func inlineApprovalStatus(_ controller: CallerApprovalController) -> some View {
        WorkflowInspectorApprovalStatus(controller: controller)
    }

}
