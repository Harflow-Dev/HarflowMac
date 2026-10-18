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

import MonitorCore
import PbUI
import SwiftUI

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
    let activityRows: [ActivityRow]
    /// The "what is it doing now" line under the feed; `nil` unless a call is pending in a running turn.
    let liveStep: LiveStep?
    var pendingMessages: [PendingMessage] = []
    /// True while NO member of this conversation has any timeline item yet AND at least one
    /// member's own event stream is still `.loading` (Monitor piece 12, Design point 4, extended
    /// across every member for piece 13) — the column shows `SkeletonRows` instead of the empty
    /// timeline while this holds.
    let isLoading: Bool
    var emptyText: String?
    /// From the current member's snapshot only — no fallback to `task.summary` (F4-40, a deliberate
    /// difference from `ChangesPane`). A settled lane shows it first, as its result callout.
    let summary: String?
    /// The lane feed's step-count copy ("1 step"/"N steps"); `nil` while no item row is loaded —
    /// a zero, still-loading or unavailable feed omits the count rather than claiming "0 steps".
    var stepCountText: String?
    /// "No tool calls recorded", proven only for a terminal current task from the UNFILTERED
    /// member inputs — never inferred from the visible page having none.
    var noToolCallsText: String?
    let onTapTakeover: () -> Void
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

    /// "<Backend> · <repo name>" plus "· N turns" when `turns > 1` — the lane header's subtitle,
    /// without the session id.
    static func subtitle(repoPath: String, backend: String, turns: Int) -> String {
        var parts = [BackendStyle.displayName(backend), Format.repoName(repoPath)].filter { !$0.isEmpty }
        if turns > 1 { parts.append("\(turns) turns") }
        return parts.joined(separator: " · ")
    }

    /// Raw item count excludes conversation separators.
    static func itemCount(_ rows: [ConversationTimelineRow]) -> Int {
        rows.filter { if case .item = $0.kind { return true }; return false }.count
    }
}

// MARK: - ParallelColumnView

struct ParallelColumnView: View {
    let model: ParallelColumnModel
    @State private var state: ParallelColumnUIState
    @State private var resultContentSize = CGSize(width: PbRadius.Metrics.zero, height: PbRadius.Metrics.parallelResultMaximumHeight)

    init(model: ParallelColumnModel, state: ParallelColumnUIState? = nil) {
        self.model = model
        _state = State(initialValue: state ?? ParallelColumnUIState())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing10) {
            header
            if let message = model.outcomeMessage {
                Text(message).font(.pb(.caption)).foregroundStyle(Color.secondaryText)
            }
            if model.showPrompt, let prompt = model.prompt { PromptBubbleView(text: prompt) }
            Divider()
            resultCallout
            if model.isLoading, model.liveStep == nil {
                SkeletonRows(count: 4, showsBadge: false)
.padding(.top, PbRadius.Metrics.spacing4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                feed.pbFadeIn()
            }
        }
        .padding(PbRadius.Metrics.spacing16)
        .frame(maxHeight: .infinity, alignment: .top)
        .opensFileLinks(repoPath: model.task.repoPath)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
            HStack(alignment: .top, spacing: PbRadius.Metrics.spacing8) {
                StatusIcon(status: model.task.status)
                VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing2) {
                    Text(model.title).font(.pb(.headline, weight: .semibold)).lineLimit(2)
                    HStack(spacing: PbRadius.Metrics.spacing6) {
                        BackendDot(backend: model.task.backend)
                        Text(model.subtitle).font(.pb(.secondary)).monospacedDigit().foregroundStyle(Color.secondaryText).lineLimit(1)
                    }
                }
                Spacer(minLength: PbRadius.Metrics.spacing8)
                TaskStatusLabel(task: model.task).fixedSize()
            }
            HStack(spacing: PbRadius.Metrics.spacing10) {
                Button("Open task") { model.onTapOpenTask() }.buttonStyle(.link)
                Spacer(minLength: PbRadius.Metrics.spacing8)
                if model.isBusy { ProgressView().controlSize(.small) }
                if WorkflowNodePresentation.allowsTerminal(model.task) {
                // §4: one action, one name — "Take over in terminal" for an active AND a settled
                // lane; the confirmation dialog matches this copy for both.
                TerminalActionButton("Take over in terminal", action: model.onTapTakeover)
                    .disabled(model.task.sessionID == nil || model.isBusy)
                }
            }
            .font(.pb(.secondary))
        }
    }

    // MARK: Result callout

    /// A settled lane shows its current-member snapshot's result FIRST (§6.5) — in a `doneBG`
    /// callout when it succeeded, truthfully tinted for a failure or cancellation. The summary is
    /// the snapshot's own, with no fallback to `task.summary`, and an empty or missing one is
    /// omitted entirely. Long results scroll independently within a bounded callout so activity
    /// remains reachable without changing the activity feed's own identity or scroll state.
    @ViewBuilder
    private var resultCallout: some View {
        if let summary = model.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           model.task.status.isTerminal {
            ScrollView {
                MarkdownText(text: summary)
                    .padding(PbRadius.Metrics.spacing12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                        if resultContentSize != size { resultContentSize = size }
                    }
                    .background(ActivityScrollChrome())
            }
            .frame(height: min(resultContentSize.height, PbRadius.Metrics.parallelResultMaximumHeight))
            .background(RoundedRectangle(cornerRadius: PbRadius.card).fill(resultBackground))
            .overlay(RoundedRectangle(cornerRadius: PbRadius.card).stroke(Color.cardBorder, lineWidth: PbRadius.Metrics.hairlineStroke))
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

    private var feed: some View {
        VStack(spacing: PbRadius.Metrics.spacing8) {
            if model.stepCountText != nil || model.noToolCallsText != nil {
                HStack(spacing: PbRadius.Metrics.spacing8) {
                    if let stepCountText = model.stepCountText {
                        Text(stepCountText).font(.pb(.secondary)).monospacedDigit().foregroundStyle(Color.secondaryText)
                    }
                    if let noToolCallsText = model.noToolCallsText {
                        Text(noToolCallsText).font(.pb(.secondary)).foregroundStyle(Color.tertiaryText)
                    }
                    Spacer()
                }
            }
            ActivityFeedView(rows: model.activityRows, start: model.start, history: model.history,
                             isLoading: model.isLoading, tailValue: ActivityFeedTail(liveStep: model.liveStep, pendingMessages: model.pendingMessages),
                             paginationRevision: model.paginationRevision, isVisible: model.isVisible,
                             emptyText: model.emptyText, showsPromptBubble: false, state: state, onLoadMore: model.onLoadMore,
                             tailPresentation: .standard(.init(
                                pendingMessages: model.pendingMessages,
                                liveStep: model.liveStep.map { .init(text: $0.text, indicator: .threeDots) }
                             )), onSelectChildTask: model.onSelectTask)
        }
    }
}

#if DEBUG
private func previewTask(id: String, age: TimeInterval, status: String = "running") -> TaskInfo {
    TaskInfo(.object([
        "task_id": .string(id), "backend": .string("claude"), "status": .string(status), "repo_path": .string("/Users/me/Code/polybridge"),
        "started_at": .string(ISO8601DateFormatter().string(from: .now.addingTimeInterval(-age)))
    ]))!
}

@MainActor
private func previewColumn(_ model: ParallelColumnModel) -> some View {
    ParallelColumnView(model: model)
        .frame(width: PbRadius.Metrics.parallelColumnPreviewWidth, height: PbRadius.Metrics.parallelColumnPreviewHeight)
        .background(Color.windowBG)
}

@MainActor
private func columnModel(
    id: String = "abc123", task: TaskInfo, rows: [ConversationTimelineRow], isLoading: Bool = false, turns: Int = 1,
    summary: String? = nil, liveStep: LiveStep? = nil
) -> ParallelColumnModel {
    ParallelColumnModel(
        id: id, task: task, title: "Fix the login bug",
        subtitle: ParallelColumnModel.subtitle(repoPath: "/Users/me/Code/polybridge", backend: task.backend, turns: turns),
        isBusy: false, outcomeMessage: nil, showPrompt: false, prompt: nil,
        rows: rows, activityRows: ActivityRowsBuilder.build(from: rows), liveStep: liveStep ?? LiveStep(rows: rows), isLoading: isLoading,
        summary: summary, onTapTakeover: {}, onTapOpenTask: {}
    )
}

private var followUpRows: [ConversationTimelineRow] {
    [
        ConversationTimelineRow(
            id: "t1#1", taskID: "t1", timestamp: .now.addingTimeInterval(-90),
            kind: .item(PreviewFixtures.textItem("Looked at the failing test.")), live: false
        ),
        ConversationTimelineRow(
            id: "sep:t2", taskID: "t2", timestamp: .now,
            kind: .separator(text: "Also add a test for the edge case"), live: false
        ),
        ConversationTimelineRow(id: "t2#1", taskID: "t2", timestamp: .now, kind: .item(PreviewFixtures.finishedItem()), live: true)
    ]
}

#Preview("Running - light") {
    previewColumn(columnModel(task: previewTask(id: "abc123", age: 90), rows: PreviewFixtures.sampleRows(taskID: "abc123")))
        .preferredColorScheme(.light)
}

#Preview("Running - dark") {
    previewColumn(columnModel(task: previewTask(id: "abc123", age: 90), rows: PreviewFixtures.sampleRows(taskID: "abc123")))
        .preferredColorScheme(.dark)
}

#Preview("Finished - light") {
    previewColumn(columnModel(
        task: previewTask(id: "abc123", age: 90, status: "completed"), rows: PreviewFixtures.sampleRows(taskID: "abc123", running: false),
        summary: "Fixed the **flaky** login test by warming the keychain first."
    ))
    .preferredColorScheme(.light)
}

#Preview("Finished - dark") {
    previewColumn(columnModel(
        task: previewTask(id: "abc123", age: 90, status: "completed"), rows: PreviewFixtures.sampleRows(taskID: "abc123", running: false),
        summary: "Fixed the **flaky** login test by warming the keychain first."
    ))
    .preferredColorScheme(.dark)
}

#Preview("Long result - light") {
    previewColumn(longResultColumnModel()).preferredColorScheme(.light)
}

#Preview("Long result - dark") {
    previewColumn(longResultColumnModel()).preferredColorScheme(.dark)
}

@MainActor
private func longResultColumnModel() -> ParallelColumnModel {
    columnModel(task: previewTask(id: "abc123", age: 90, status: "completed"),
                rows: PreviewFixtures.sampleRows(taskID: "abc123", running: false),
                summary: Array(repeating: "The completed review includes a detailed result that remains scrollable above activity.", count: 20)
                    .joined(separator: "\n\n"))
}

#Preview("Loading column - light") {
    previewColumn(columnModel(task: previewTask(id: "abc123", age: 2), rows: [], isLoading: true)).preferredColorScheme(.light)
}

#Preview("Loading column - dark") {
    previewColumn(columnModel(task: previewTask(id: "abc123", age: 2), rows: [], isLoading: true)).preferredColorScheme(.dark)
}

#Preview("With a follow-up turn - light") {
    previewColumn(columnModel(id: "t1", task: previewTask(id: "t2", age: 90), rows: followUpRows, turns: 2))
        .preferredColorScheme(.light)
}

#Preview("With a follow-up turn - dark") {
    previewColumn(columnModel(id: "t1", task: previewTask(id: "t2", age: 90), rows: followUpRows, turns: 2))
        .preferredColorScheme(.dark)
}

#Preview("Prose-only, no tools recorded - light") {
    previewColumn(noToolsColumnModel())
        .preferredColorScheme(.light)
}

#Preview("Prose-only, no tools recorded - dark") {
    previewColumn(noToolsColumnModel())
        .preferredColorScheme(.dark)
}

#Preview("Live step, three dots - light") {
    previewColumn(liveStepColumnModel()).preferredColorScheme(.light)
}

#Preview("Live step, three dots - dark") {
    previewColumn(liveStepColumnModel()).preferredColorScheme(.dark)
}

@MainActor
private func noToolsColumnModel() -> ParallelColumnModel {
    // A complete, settled, prose-only turn: the count reads "1 step" and the proven
    // "No tool calls recorded" note shows beside it.
    let rows = [ConversationTimelineRow(
        id: "abc123#1", taskID: "abc123", timestamp: .now.addingTimeInterval(-30),
        kind: .item(PreviewFixtures.textItem("Reviewed the diff and left one comment.")), live: false
    )]
    var model = columnModel(task: previewTask(id: "abc123", age: 30, status: "completed"), rows: rows)
    model.stepCountText = "1 step"
    model.noToolCallsText = "No tool calls recorded"
    return model
}

@MainActor
private func liveStepColumnModel() -> ParallelColumnModel {
    let rows = PreviewFixtures.sampleRows(taskID: "abc123")
    var model = columnModel(task: previewTask(id: "abc123", age: 10), rows: rows,
                            liveStep: LiveStep(rows: rows, isRunning: true))
    model.stepCountText = "6 steps"
    return model
}
#endif
