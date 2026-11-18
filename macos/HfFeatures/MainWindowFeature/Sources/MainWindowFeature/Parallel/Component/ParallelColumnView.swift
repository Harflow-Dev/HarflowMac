//
//  ParallelColumnView.swift
//  MainWindowFeature
//
//  Presentation and action closures come from the VM. Lightweight reading and disclosure state
//  survives viewport eviction; measured row geometry stays local to this mounted activity view.
//
//  Monitor piece 13: a column is one agent CONVERSATION (a resume chain), not one task — `rows` is
//  the whole conversation's concatenated timeline (`MonitorCore.ConversationTimeline`, the same
//  shape TaskDetail's own `TimelinePaneView` renders), with a turn separator ahead of every
//  follow-up and each row's own `live` flag already scoped to its own turn.
//
//  Redesign follow-up: the header and feed mirror the single-task screen — `activityRows` is `rows`
//  folded into tool cards by the VM (`ActivityRowsBuilder`), rendered exactly like `TimelinePaneView`.
//

import AppKit
import HfRepository
import HfUI
import MonitorCore
import SwiftUI

// MARK: - ParallelColumnChrome

/// Which surface draws a column. `.lane` is the HarflowDesign v2 lane (group and workflow-run Parallel);
/// `.inspector` is the Graph selected-node inspector's column: the page background, no status strip, and the system divider.
enum ParallelColumnChrome: Equatable, Sendable {
    case lane
    case inspector
}

// MARK: - ParallelMessageLock

/// A workflow-owned reason, beyond takeover, that a column's composer cannot take a message.
enum ParallelMessageLock: Equatable, Sendable {
    /// The run whose lanes these are was cancelled; the lane composers lock with the approved copy.
    case runCancelled
    /// The runtime has no queued messaging; the node pane's inspector composer locks bare, like the task screen's.
    case messagingUnsupported
}

// MARK: - ParallelColumnView

struct ParallelColumnView: View {
    let model: ParallelColumnModel
    @FocusState private var historyBoundaryFocused: Bool
    @State private var headFocusToken = 0
    /// The lane body's height, so the block above the feed can be capped at 40% of it.
    @State private var laneBodyHeight: CGFloat = 0
    /// The leading block's natural height; it is shown whole up to the cap, then scrolls.
    @State private var leadingBlockHeight: CGFloat = 0
    /// The inspector column's height and its approval panel's natural height, which cap the approval region.
    @State private var inspectorHeight: CGFloat = 0
    @State private var approvalNaturalHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var outcomeHeight: CGFloat = 0
    @State private var boundaryHeight: CGFloat = 0
    @State private var composerHeight: CGFloat = 0
    /// The inspector's step-count line above the feed, measured so its height and the gap below it reach the pane's reserve.
    @State private var countLineHeight: CGFloat = 0
    @State private var adoptionFocus = AdoptionFocusTracker()
    @State private var state: ParallelColumnUIState
    @State private var resultContentSize = CGSize(width: HfRadius.Metrics.zero, height: HfRadius.Metrics.parallelResultMaximumHeight)

    init(model: ParallelColumnModel, state: ParallelColumnUIState? = nil) {
        self.model = model
        _state = State(initialValue: state ?? ParallelColumnUIState())
    }

    var body: some View {
        Group {
            switch model.chrome {
            case .lane: laneBody
            case .inspector: inspectorBody
            }
        }
        .opensFileLinks(repoPath: model.task.repoPath)
    }

    // MARK: Lane chrome

    /// HarflowDesign v2 `.hd-lane`: head (12/16 padding, bottom hairline), body (the feed fills it edge to
    /// edge; items outside the feed carry their own 16 pt side padding, 12 pt row gap) and foot (12 pt
    /// padding, top hairline) holding the composer.
    private var laneBody: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.zero) {
            ParallelLaneHead(title: model.title, caption: model.laneCaption, task: model.task, status: model.laneStatus,
                             onOpenTask: model.onTapOpenTask, focusToken: headFocusToken)
                .padding(.horizontal, HfRadius.Metrics.spacing16)
                .padding(.vertical, HfRadius.Metrics.spacing12)
            laneHairline
            // `.hd-lane__body`: padding 16, gap 12. The block above the feed exists only when it has content and owns
            // the top 16; the feed owns its first entry's top padding: 16 under the head, or the 12 pt row gap under a
            // block (`ActivityFeedStyle.laneAfterBlock`), so nothing overlaps.
            VStack(alignment: .leading, spacing: HfRadius.Metrics.zero) {
                if hasLeadingBlock {
                    leadingBlock
                        .padding(.horizontal, TaskScreenStyle.Lane.paddingHorizontal)
                        .padding(.top, TaskScreenStyle.Lane.paddingTop)
                }
                // The feed fills the body edge to edge and supplies its own 16 pt insets through `.lane`.
                SkeletonContent(isLoading: laneFeedIsLoading, state: state.activityHandoff) {
                    SkeletonRows(count: 4, showsBadge: false)
                        .padding(.top, feedStyle.topPadding)
                        .padding(.horizontal, TaskScreenStyle.Lane.paddingHorizontal)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } content: {
                    feed
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { if laneBodyHeight != $0 { laneBodyHeight = $0 } }
            laneHairline
            VStack(alignment: .leading, spacing: TaskScreenStyle.Lane.rowGap) {
                // While the feed shows its skeleton the outcome has no tail to sit in, so it sits above the composer.
                if laneFeedIsLoading, let message = model.outcomeMessage {
                    Text(message)
                        .font(TaskScreenStyle.sans(size: 13))
                        .lineSpacing(TaskScreenStyle.lineSpacing(.init(size: 13, lineHeight: 20)))
                        .foregroundStyle(TaskScreenStyle.Colors.textSecondary.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("parallel-column-outcome")
                }
                composer
            }
            .padding(HfRadius.Metrics.spacing12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: model.cachedHistoryNotice) { old, notice in
            switch adoptionFocus.noticeChanged(from: old, to: notice) {
            case .loaded:
                // "Load current activity" completed: the notice is gone, so the head takes focus and says so.
                headFocusToken += 1
                NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                    userInfo: [.announcement: "Current activity loaded", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            case .failed, .none:
                break
            }
        }
        // The outcome line is announced once when it first appears (in the tail or, while loading, above the composer)
        // and again only when it changes; the lane's UI state remembers the last one across recycled views.
        .onChange(of: model.outcomeMessage, initial: true) { _, outcome in
            if state.shouldAnnounce(outcome: outcome), let outcome { ParallelOutcomeAnnouncer.announce(outcome) }
        }
    }

    private var laneFeedIsLoading: Bool { model.isLoading && model.liveStep == nil }

    /// Whether anything draws above the lane's feed.
    private var hasLeadingBlock: Bool {
        (model.showPrompt && model.request != nil) || model.cachedHistoryNotice != nil
    }

    /// The prompt (View prompt) first, then the history boundary, matching the drawing's order. The block is pinned above
    /// the feed and capped at 40% of the lane body, scrolling inside when taller.
    @ViewBuilder private var leadingBlock: some View {
        let block = VStack(alignment: .leading, spacing: TaskScreenStyle.Lane.rowGap) {
            if model.showPrompt, let request = model.request {
                StoredRequestView(state: request, read: { model.onReadRequest?($0) }, copy: { model.onCopyRequest?($0) },
                                  initiallyExpanded: true)
                    .accessibilityIdentifier("parallel-lane-request")
                if let feedback = model.requestFeedback {
                    Text(feedback).font(TaskScreenStyle.sans(size: 12)).foregroundStyle(TaskScreenStyle.Colors.textTertiary.color)
                }
            }
            laneHistoryBoundary
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One structure whatever is measured, so the first measurement never rebuilds the block (and loses request or
        // notice focus state): a scroll view whose height is the block's natural height up to 40% of the lane body.
        ScrollView { block.onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { leadingBlockHeight = $0 } }
            .background(ActivityScrollChrome())
            .frame(height: min(leadingBlockHeight, laneBodyHeight > 0 ? laneBodyHeight * 0.4 : .infinity))
    }

    private var laneHairline: some View {
        Rectangle()
            .fill(TaskScreenStyle.Colors.border.color)
            .frame(height: ParallelLayout.dividerWidth)
            .accessibilityHidden(true)
    }

    // MARK: Inspector chrome

    /// The Graph inspector's earlier column, unchanged.
    private var inspectorBody: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing10) {
            header.measured(into: $headerHeight)
            if let message = model.outcomeMessage {
                Text(message).font(.hf(.caption)).foregroundStyle(Color.secondaryText).measured(into: $outcomeHeight)
            }
            inspectorHistoryBoundary.measured(into: $boundaryHeight)
            Divider()
            resultCallout
            SkeletonContent(isLoading: model.isLoading && model.liveStep == nil, state: state.activityHandoff) {
                SkeletonRows(count: 4, showsBadge: false)
                    .padding(.top, HfRadius.Metrics.spacing4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } content: {
                feed
            }
            inspectorApprovalRegion
            composer.measured(into: $composerHeight)
        }
        .padding(HfRadius.Metrics.spacing16)
        .frame(maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { inspectorHeight = $0 }
        .preference(key: WorkflowSelectedColumnChromeKey.self, value: inspectorChrome)
    }

    /// The approval region's height: derived from measured inputs only, never from itself or from `inspectorChrome`'s feed.
    private var approvalRegionHeight: CGFloat {
        model.inspectorApproval == nil ? 0
            : WorkflowSelectedPaneSizing.approvalHeight(natural: approvalNaturalHeight, columnHeight: inspectorHeight, chrome: inspectorChrome)
    }

    /// Everything in the column that is neither the feed nor the approval region, from directly measured pieces: header,
    /// outcome line, history boundary, divider, result callout, the step-count line (while it is drawn) and composer, plus the stack's padding and spacing.
    private var inspectorChrome: CGFloat {
        let outcome = model.outcomeMessage == nil ? 0 : outcomeHeight
        let callout = showsResultCallout ? min(resultContentSize.height, HfRadius.Metrics.parallelResultMaximumHeight) : 0
        let countLine = showsCountLine ? countLineHeight + HfRadius.Metrics.spacing8 : 0
        // The 5 assumes the header, history boundary, divider, feed and composer are always mounted.
        let count = 5 + (model.outcomeMessage == nil ? 0 : 1) + (showsResultCallout ? 1 : 0) + (model.inspectorApproval == nil ? 0 : 1)
        return WorkflowSelectedPaneSizing.columnChrome(
            pieces: [headerHeight, outcome, boundaryHeight, ParallelLayout.dividerWidth, callout, composerHeight, countLine], itemCount: count)
    }

    /// The node task's approval panel between the feed and the composer: it takes its natural height up to
    /// `WorkflowSelectedPaneSizing.approvalShare` of the column, then scrolls, so the feed keeps its floor.
    @ViewBuilder private var inspectorApprovalRegion: some View {
        if let gate = model.inspectorApproval {
            ScrollView {
                CallerApprovalPanel(taskID: model.task.taskID, polls: gate.polls)
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { approvalNaturalHeight = $0 }
                    .background(ScrollChrome())
            }
            .frame(height: approvalRegionHeight)
            .accessibilityIdentifier("workflow-selected-approval")
        }
    }

    /// The lane's boundary block (`.hd-d2b-boundary`): drawn only while there is a notice.
    @ViewBuilder private var laneHistoryBoundary: some View {
        if let notice = model.cachedHistoryNotice {
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
                Text(notice)
                    .font(TaskScreenStyle.sans(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .focusable()
                    .focused($historyBoundaryFocused)
                if let adopt = model.onAdoptWindow {
                    Button("Load current activity") {
                        adoptionFocus.requestAdoption()
                        adopt()
                        historyBoundaryFocused = true
                        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                            userInfo: [.announcement: "Loading current activity; the cached reading window will be replaced.",
                                       .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(TaskScreenStyle.Scale.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: TaskScreenStyle.Scale.radiusMedium).fill(TaskScreenStyle.Colors.surfaceSunken.color))
            .overlay(RoundedRectangle(cornerRadius: TaskScreenStyle.Scale.radiusMedium)
                .strokeBorder(TaskScreenStyle.Colors.border.color, lineWidth: HfRadius.Metrics.hairlineStroke))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("History boundary")
        }
    }

    private var inspectorHistoryBoundary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.cachedHistoryNotice ?? "Available captured history")
                .font(.hf(.caption))
                .fixedSize(horizontal: false, vertical: true)
                .focusable()
                .focused($historyBoundaryFocused)
            if let adopt = model.onAdoptWindow {
                Button("Load current activity") {
                    adopt()
                    historyBoundaryFocused = true
                    NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                        userInfo: [.announcement: "Loading current activity; the cached reading window will be replaced.",
                                   .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                }
            }
        }
    }

    @ViewBuilder
    private var composer: some View {
        if model.chrome == .lane { laneComposer } else { inspectorComposer }
    }

    /// The lane's composer: Queue only (no Send now), labelled for the harness, with a note when messaging is unavailable.
    private var laneComposer: some View {
        let harness = model.laneHarnessName
        return VStack(alignment: .leading, spacing: HfRadius.Metrics.zero) {
            MessageBoxView(model: model.laneMessageBoxModel, style: .lane) { model.onSubmitMessage?($0, false) ?? false }
            if model.onSubmitMessage == nil {
                Text("Messaging is unavailable for this activity view.")
                    .font(TaskScreenStyle.sans(size: 13))
                    .lineSpacing(TaskScreenStyle.lineSpacing(.init(size: 13, lineHeight: 20)))
                    .foregroundStyle(TaskScreenStyle.Colors.textSecondary.color)
                    .padding(.top, TaskScreenStyle.Scale.space2)
            }
        }
        .anchorPreference(key: ParallelComposerBounds.self, value: .bounds) { [model.id: $0] }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message \(harness): \(model.title)")
        .accessibilityIdentifier("parallel-column-composer")
    }

    private var inspectorComposer: some View {
        VStack(spacing: HfRadius.Metrics.zero) {
            MessageBoxView(model: model.inspectorMessageBoxModel,
                           onSubmitNow: { model.onSubmitMessage?($0, true) ?? false }, isCompact: true) { model.onSubmitMessage?($0, false) ?? false }
            if model.onSubmitMessage == nil {
                Text("Messaging is unavailable for this activity view.")
                    .font(.hf(.caption))
.foregroundStyle(Color.secondaryText)
            }
        }
        .anchorPreference(key: ParallelComposerBounds.self, value: .bounds) { [model.id: $0] }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Messages for \(model.title)")
        .accessibilityIdentifier("parallel-column-composer")
    }

    // MARK: Inspector header

    /// The inspector header: the actions row, preceded by the task's title, subtitle and status row only where the pane head
    /// does not already name the node and its status (the orchestrator pane).
    private var header: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            if model.showsInspectorTitle {
                HStack(alignment: .top, spacing: HfRadius.Metrics.spacing8) {
                    StatusIcon(status: model.task.status)
                    VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing2) {
                        Text(model.title).font(.hf(.headline, weight: .semibold)).lineLimit(2)
                        HStack(spacing: HfRadius.Metrics.spacing6) {
                            BackendDot(backend: model.task.backend)
                            Text(model.subtitle).font(.hf(.secondary)).monospacedDigit().foregroundStyle(Color.secondaryText).lineLimit(1)
                        }
                    }
                    Spacer(minLength: HfRadius.Metrics.spacing8)
                    TaskStatusLabel(task: model.task).fixedSize()
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: HfRadius.Metrics.spacing10) {
                    openTaskAction
                    Spacer(minLength: HfRadius.Metrics.spacing8)
                    terminalAction
                }
                VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
                    openTaskAction
                    terminalAction
                }
            }
            .font(.hf(.secondary))
        }
    }

    private var openTaskAction: some View {
        Button("Open task") { model.onTapOpenTask() }.buttonStyle(.link)
    }

    @ViewBuilder
    private var terminalAction: some View {
        if model.isBusy { ProgressView().controlSize(.small) }
        if WorkflowNodePresentation.allowsTerminal(model.task), let takeover = model.onTapTakeover {
            TerminalActionButton("Take over in terminal", action: takeover)
                .disabled(model.task.sessionID == nil || model.isBusy)
        }
    }

    // MARK: Result callout

    /// A settled lane shows its current-member snapshot's result FIRST (§6.5) — in a `doneBG`
    /// callout when it succeeded, truthfully tinted for a failure or cancellation. The summary is
    /// the snapshot's own, with no fallback to `task.summary`, and an empty or missing one is
    /// omitted entirely. Long results scroll independently within a bounded callout so activity
    /// remains reachable without changing the activity feed's own identity or scroll state.
    private var showsResultCallout: Bool {
        guard let summary = model.summary else { return false }
        return !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.task.status.isTerminal
    }

    @ViewBuilder
    private var resultCallout: some View {
        if showsResultCallout, let summary = model.summary {
            ScrollView {
                MarkdownText(text: summary)
                    .padding(HfRadius.Metrics.spacing12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                        if resultContentSize != size { resultContentSize = size }
                    }
                    .background(ActivityScrollChrome())
            }
            .frame(height: min(resultContentSize.height, HfRadius.Metrics.parallelResultMaximumHeight))
            .background(RoundedRectangle(cornerRadius: HfRadius.card).fill(resultBackground))
            .overlay(RoundedRectangle(cornerRadius: HfRadius.card).stroke(Color.cardBorder, lineWidth: HfRadius.Metrics.hairlineStroke))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Result")
        }
    }

    /// The result callout's background: the state's own tint, never a status colour as a fill for
    /// anything but this callout.
    private var resultBackground: Color {
        switch model.task.status {
        case .completed: Color.doneBG
        case .failed, .timedOut: Color.dangerBG
        case .cancelled: Color.neutralFill
        case .running, .other: Color.cardFill
        }
    }

    // MARK: Feed

    /// Lanes use the transcript metrics at lane insets; the inspector keeps the standard feed.
    private var feedStyle: ActivityFeedStyle {
        guard model.chrome == .lane else { return .standard }
        return hasLeadingBlock ? .laneAfterBlock : .lane
    }

    /// The lane's rows: with the settled end row shown, the feed's own trailing "Finished" marker is dropped, so a settled lane
    /// ends with the end row only. The task screen and the inspector keep it.
    private var laneActivityRows: [ActivityRow] {
        guard model.chrome == .lane, !laneFeedIsLoading, ParallelLaneStatus.settledLine(current: model.task, status: model.laneStatus) != nil,
              model.activityRows.last?.isFinishedMarker == true else { return model.activityRows }
        return Array(model.activityRows.dropLast())
    }

    /// The inspector keeps the count line; the lane drops it (Simplify).
    private var showsCountLine: Bool {
        model.chrome == .inspector && !laneFeedIsLoading && (model.stepCountText != nil || model.noToolCallsText != nil)
    }

    private var feed: some View {
        VStack(spacing: HfRadius.Metrics.spacing8) {
            if showsCountLine {
                HStack(spacing: HfRadius.Metrics.spacing8) {
                    if let stepCountText = model.stepCountText {
                        Text(stepCountText).font(.hf(.secondary)).monospacedDigit().foregroundStyle(Color.secondaryText)
                    }
                    if let noToolCallsText = model.noToolCallsText {
                        Text(noToolCallsText).font(.hf(.secondary)).foregroundStyle(Color.tertiaryText)
                    }
                    Spacer()
                }
                .measured(into: $countLineHeight)
            }
            ActivityFeedView(rows: laneActivityRows, activitySnapshot: model.activitySnapshot, start: model.start, history: model.history,
                             isLoading: model.isLoading, tailValue: ActivityFeedTail(liveStep: model.liveStep, pendingMessages: model.pendingMessages),
                             paginationRevision: model.paginationRevision, isVisible: model.isVisible,
                             emptyText: model.emptyText, horizontalPadding: feedStyle.horizontalPadding(standard: HfRadius.Metrics.zero),
                             showsPromptBubble: false, style: feedStyle, state: state, onLoadMore: model.onLoadMore,
                             tailPresentation: .standard(.init(
                                pendingMessages: model.pendingMessages,
                                workMessages: model.workMessages,
                                liveStep: model.liveStep.map { .init(text: $0.text, indicator: model.chrome == .lane ? .singleDot : .threeDots) },
                                cancel: model.onCancelMessage == nil ? .hidden : (model.isBusy ? .disabled : .enabled),
                                outcome: model.chrome == .lane && !laneFeedIsLoading ? model.outcomeMessage : nil,
                                settled: model.chrome == .lane && !laneFeedIsLoading
                                    ? ParallelLaneStatus.settledLine(current: model.task, status: model.laneStatus) : nil
                             )), onSelectChildTask: model.onSelectTask,
                             onCancelQueuedMessage: model.onCancelMessage)
        }
    }
}

// MARK: - ParallelComposerBounds

/// Local layout observation; no product state or rendering publisher consumes these anchors.
struct ParallelComposerBounds: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

// MARK: - Measured height

private extension View {
    /// Writes this view's laid-out height into `height` when it changes.
    func measured(into height: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height.wrappedValue = $0 }
    }
}
