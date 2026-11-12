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
import HfUI
import MonitorCore
import SwiftUI

// MARK: - ParallelColumnChrome

/// Which surface draws a column. `.lane` is the HarflowDesign v2 lane (group and workflow-run Parallel);
/// `.inspector` keeps the Graph selected-node inspector's earlier chrome until it has its own v2 design.
enum ParallelColumnChrome: Equatable, Sendable {
    case lane
    case inspector
}

// MARK: - ParallelColumnModel

/// Presentation data for one Parallel column: the conversation's fresh CURRENT member (status,
/// take-over and buttons all act on it), everything today's outcome line/busy state/event stream say
/// about it, and the two actions its buttons perform.
struct ParallelColumnModel: Identifiable {
    let id: String
    let task: TaskInfo
    let title: String
    /// "<Backend> · <repo name>", plus "· N turns" once the conversation has more than one turn.
    let subtitle: String
    let isBusy: Bool
    let outcomeMessage: String?
    let showPrompt: Bool
    let prompt: String?
    /// Raw timeline items and separators for the complete step count.
    let rows: [ConversationTimelineRow]
    /// What the feed renders: `rows` with adjacent tool calls folded into cards.
    var activitySnapshot: ActivityFeedSnapshot?
    let activityRows: [ActivityRow]
    /// The "what is it doing now" line under the feed; `nil` unless a call is pending in a running turn.
    var liveStep: LiveStep?
    var pendingMessages: [PendingMessage] = []
    var workMessages: [WorkMessageBubble] = []
    /// True while NO member of this conversation has any timeline item yet AND at least one
    /// member's own event stream is still `.loading` (Monitor piece 12, Design point 4, extended
    /// across every member for piece 13) — the column shows `SkeletonRows` instead of the empty
    /// timeline while this holds.
    var isLoading: Bool
    var emptyText: String?
    /// From the current member's snapshot only — no fallback to `task.summary` (F4-40, a deliberate
    /// difference from `ChangesPane`). A settled lane shows it first, as its result callout.
    let summary: String?
    /// The lane feed's activity-item count; `nil` while no item row is loaded —
    /// a zero, still-loading or unavailable feed omits the count rather than claiming "0 activity items".
    var stepCountText: String?
    /// "No tool calls recorded", proven only for a terminal current task from the UNFILTERED
    /// member inputs — never inferred from the visible page having none.
    var noToolCallsText: String?
    /// Take over in a terminal; only the Graph inspector offers it (a lane's actions menu holds Open task only).
    var onTapTakeover: (() -> Void)?
    let onTapOpenTask: () -> Void
    /// Opens another task by id (a consumed follow-up's successor).
    var onSelectTask: ((String) -> Void)?
    /// When the conversation's FIRST turn started — every row's elapsed time counts from here, as
    /// TaskDetail's Timeline does; the current turn's own start would clamp earlier turns to 0.
    var start: Date?
    var animatesArrival = false
    var onDidPresent: () -> Void = {}
    var memberTaskIDs: Set<String> = []
    var isResident = true
    var isVisible = true
    var history = EventHistoryState()
    var paginationRevision = 0
    var onLoadMore: (() -> Bool)?
    var cachedHistoryNotice: String?
    var onAdoptWindow: (() -> Void)?
    var onSubmitMessage: ((String, Bool) -> Bool)?
    var onCancelMessage: ((String) -> Void)?
    /// The surface that draws this column; the VM sets `.inspector` for the Graph inspector's VM.
    var chrome = ParallelColumnChrome.lane
    /// The lane caption under the title: "Claude · Opus 5.5", plus " · taken over". Empty means derive from `task`.
    var caption = ""
    /// The harness name for the composer labels. Empty means derive from `task`.
    var harnessName = ""
    /// The lane head's status. `nil` means derive from `task` alone.
    var status: TaskBadgeModel?

    var laneCaption: String { caption.isEmpty ? ParallelLaneStatus.caption(current: task) : caption }
    var laneHarnessName: String { harnessName.isEmpty ? ParallelLaneStatus.harnessName(current: task) : harnessName }
    var laneStatus: TaskBadgeModel { status ?? ParallelLaneStatus.make(current: task, snapshot: nil, frame: nil) }

    /// "<Backend> · <repo name>" plus "· N turns" when `turns > 1` — the lane header's subtitle,
    /// without the session id.
    static func subtitle(repoPath: String, backend: String, turns: Int) -> String {
        var parts = [BackendStyle.displayName(backend), Format.repoName(repoPath)].filter { !$0.isEmpty }
        if turns > 1 { parts.append("\(turns) turns") }
        return parts.joined(separator: " · ")
    }

    /// The same column drawn by another surface. The Graph inspector forces `.inspector` so it keeps its
    /// earlier chrome until it receives a v2 design.
    func withChrome(_ chrome: ParallelColumnChrome) -> ParallelColumnModel {
        var copy = self
        copy.chrome = chrome
        return copy
    }

    /// Raw item count excludes conversation separators.
    static func itemCount(_ rows: [ConversationTimelineRow]) -> Int {
        rows.filter { if case .item = $0.kind { return true }; return false }.count
    }
}

// MARK: - ParallelColumnView

struct ParallelColumnView: View {
    let model: ParallelColumnModel
    @FocusState private var historyBoundaryFocused: Bool
    @State private var headFocusToken = 0
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
                    VStack(alignment: .leading, spacing: TaskScreenStyle.Lane.rowGap) {
                        if model.showPrompt, let prompt = model.prompt { PromptBubbleView(text: prompt) }
                        laneHistoryBoundary
                        resultCallout
                    }
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
        (model.showPrompt && model.prompt != nil) || model.cachedHistoryNotice != nil || showsResultCallout
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
            header
            if let message = model.outcomeMessage {
                Text(message).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
            }
            if model.showPrompt, let prompt = model.prompt { PromptBubbleView(text: prompt) }
            inspectorHistoryBoundary
            Divider()
            resultCallout
            SkeletonContent(isLoading: model.isLoading && model.liveStep == nil, state: state.activityHandoff) {
                SkeletonRows(count: 4, showsBadge: false)
                    .padding(.top, HfRadius.Metrics.spacing4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } content: {
                feed
            }
            composer
        }
        .padding(HfRadius.Metrics.spacing16)
        .frame(maxHeight: .infinity, alignment: .top)
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
            MessageBoxView(model: MessageBoxModel(
                canSend: !model.task.takenOver && model.onSubmitMessage != nil, canContinue: false, isBusy: model.isBusy,
                label: "Message \(harness)", hint: "",
                placeholder: model.task.takenOver ? MessageBoxDisabledReason.takenOver.text : "Message \(harness)",
                buttonLabel: "Send", isLocked: model.task.takenOver,
                fieldAccessibilityLabel: "Message \(harness)", sendAccessibilityLabel: "Send to \(harness)"
            ), style: .lane) { model.onSubmitMessage?($0, false) ?? false }
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
            MessageBoxView(model: MessageBoxModel(
                canSend: !model.task.takenOver && model.onSubmitMessage != nil, canContinue: false, isBusy: model.isBusy,
                label: "Message this task", hint: "Send queues; Send now requests immediate delivery when safe",
                placeholder: model.task.takenOver ? MessageBoxDisabledReason.takenOver.text : "Queue a message…",
                buttonLabel: "Send", isLocked: model.task.takenOver
            ), onSubmitNow: { model.onSubmitMessage?($0, true) ?? false }, isCompact: true) { model.onSubmitMessage?($0, false) ?? false }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
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

    private var feed: some View {
        VStack(spacing: HfRadius.Metrics.spacing8) {
            // The lane drops the count line (Simplify); the inspector keeps it.
            if model.chrome == .inspector, model.stepCountText != nil || model.noToolCallsText != nil {
                HStack(spacing: HfRadius.Metrics.spacing8) {
                    if let stepCountText = model.stepCountText {
                        Text(stepCountText).font(.hf(.secondary)).monospacedDigit().foregroundStyle(Color.secondaryText)
                    }
                    if let noToolCallsText = model.noToolCallsText {
                        Text(noToolCallsText).font(.hf(.secondary)).foregroundStyle(Color.tertiaryText)
                    }
                    Spacer()
                }
            }
            ActivityFeedView(rows: model.activityRows, activitySnapshot: model.activitySnapshot, start: model.start, history: model.history,
                             isLoading: model.isLoading, tailValue: ActivityFeedTail(liveStep: model.liveStep, pendingMessages: model.pendingMessages),
                             paginationRevision: model.paginationRevision, isVisible: model.isVisible,
                             emptyText: model.emptyText, horizontalPadding: feedStyle.horizontalPadding(standard: HfRadius.Metrics.zero),
                             showsPromptBubble: false, style: feedStyle, state: state, onLoadMore: model.onLoadMore,
                             tailPresentation: .standard(.init(
                                pendingMessages: model.pendingMessages,
                                workMessages: model.workMessages,
                                liveStep: model.liveStep.map { .init(text: $0.text, indicator: model.chrome == .lane ? .singleDot : .threeDots) },
                                cancel: model.onCancelMessage == nil ? .hidden : (model.isBusy ? .disabled : .enabled),
                                outcome: model.chrome == .lane && !laneFeedIsLoading ? model.outcomeMessage : nil
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
