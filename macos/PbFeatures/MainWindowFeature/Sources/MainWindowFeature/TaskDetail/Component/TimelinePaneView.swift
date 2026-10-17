//
//  TimelinePaneView.swift
//  MainWindowFeature
//
//  The Activity tab's feed. Bottom-aware following stays local `@State` per the screen
//  shape's own allowance — the VM never owns it, nor which tool cards are expanded (keyed by the
//  card's stable group id). Plain rows render through the package-root `TimelineRow` shared with the
//  Parallel screen; adjacent tool calls render as `ToolGroupCardView`s.
//
//  Monitor piece 7: `rows` is the whole conversation's concatenated timeline
//  (`MonitorCore.ConversationTimelineRow` — a globally unique id across every member, since
//  `TimelineItem.id` alone restarts per member/task), with a turn separator ahead of every
//  follow-up. Per-row `live` already reflects which turn is the current, running one (Review
//  round 1, item 1), so no separate `live` flag is needed at the pane level any more.
//
//  Redesign phase 6: `activityRows` is `rows` with tool calls folded into cards
//  (`ActivityRowsBuilder`); `rows` stays the raw list the inspector's step count reads.
//

import MonitorCore
import PbUI
import SwiftUI

// MARK: - TimelinePaneModel

struct TimelinePaneModel {
    /// The header's step count copy ("1 step"/"N steps"), `nil` while no item row is loaded — the
    /// redesign omits a zero count rather than printing "0 steps".
    let stepCountText: String?
    /// The header's conversation-turn text ("N turns"/"N decisions"), `nil` for a plain,
    /// never-followed-up task — passed through from the VM's own `turnsText`.
    var turnsText: String?
    /// "No tool calls recorded", present only when the builder proved it from the unfiltered
    /// member inputs (complete, settled, tool-free); `nil` otherwise — never claimed from an
    /// incomplete or unreadable feed.
    var noToolCallsText: String?
    /// The raw rows, one per timeline item — what the inspector's step count reads.
    let rows: [ConversationTimelineRow]
    /// What the feed renders: `rows` with adjacent tool calls folded into cards.
    let activityRows: [ActivityRow]
    let start: Date?
    let emptyText: String?
    let subTaskStrip: SubTaskStripModel?
    /// Shimmer instead of `rows`/`emptyText` (Monitor piece 11, Plan review round 1 item 4): true
    /// only while no member has any REAL event content yet (`rows` holds nothing but synthetic turn
    /// separators, if that) and at least one member's own event stream is still `.loading` — never
    /// once real content exists, and never for `.unavailable` (that keeps today's honest message).
    let isLoading: Bool
    /// The "what is it doing now" line under the feed; `nil` unless a call is pending in a running turn.
    let liveStep: LiveStep?
    /// Changes when the feed grows or changes in place; Follow live scrolls on it.
    let updateToken: ActivityUpdateToken
    let pendingMessages: [PendingMessage]
    let history: EventHistoryState
    let paginationRevision: Int
    let onLoadMore: (() -> Bool)?
    /// Opens another task by id (a consumed follow-up's successor). Independent of the sub-task
    /// strip, which only exists when the task has delegated children.
    var onSelectTask: ((String) -> Void)?

    init(
        stepCountText: String?, turnsText: String? = nil, noToolCallsText: String? = nil, rows: [ConversationTimelineRow],
        activityRows: [ActivityRow], start: Date?, emptyText: String?, subTaskStrip: SubTaskStripModel?, isLoading: Bool,
        liveStep: LiveStep?, updateToken: ActivityUpdateToken, pendingMessages: [PendingMessage] = [],
        history: EventHistoryState = EventHistoryState(), paginationRevision: Int = 0, onLoadMore: (() -> Bool)? = nil
    ) {
        self.stepCountText = stepCountText
        self.turnsText = turnsText
        self.noToolCallsText = noToolCallsText
        self.rows = rows
        self.activityRows = activityRows
        self.start = start
        self.emptyText = emptyText
        self.subTaskStrip = subTaskStrip
        self.isLoading = isLoading
        self.liveStep = liveStep
        self.updateToken = updateToken
        self.pendingMessages = pendingMessages
        self.history = history
        self.paginationRevision = paginationRevision
        self.onLoadMore = onLoadMore
    }

    /// Derives the feed rows, live step and update token from `rows` — for previews and tests; the
    /// VM builds them itself in `recomputeTimeline`.
    init(stepCountText: String?, rows: [ConversationTimelineRow], start: Date?, emptyText: String?, subTaskStrip: SubTaskStripModel?, isLoading: Bool) {
        let liveStep = LiveStep(rows: rows)
        self.init(
            stepCountText: stepCountText, rows: rows, activityRows: ActivityRowsBuilder.build(from: rows), start: start,
            emptyText: emptyText, subTaskStrip: subTaskStrip, isLoading: isLoading, liveStep: liveStep,
            updateToken: ActivityUpdateToken(rows: rows, liveStep: liveStep)
        )
    }

    @MainActor
    static let empty = TimelinePaneModel(stepCountText: nil, rows: [], start: nil, emptyText: nil, subTaskStrip: nil, isLoading: false)

    /// The header's one line: steps · turns · no-tool note, each part only when present, with
    /// tabular digits. Hidden entirely while nothing is loaded (a zero count is omitted, never
    /// printed as "0 steps").
    var headerText: String? {
        let parts = [stepCountText, turnsText, noToolCallsText].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - TimelinePaneView

struct TimelinePaneView: View {
    let model: TimelinePaneModel
    @State private var state = ParallelColumnUIState()

    var body: some View {
        VStack(spacing: PbRadius.Metrics.zero) {
            if let headerText = model.headerText {
                HStack {
                    Text(headerText).font(.pb(.secondary)).monospacedDigit().foregroundStyle(Color.secondaryText)
                    Spacer()
                }
                .padding(.horizontal, PbRadius.Metrics.spacing24)
                .padding(.vertical, PbRadius.Metrics.spacing8)
                .readingColumn()
            }
            if model.isLoading, model.liveStep == nil {
                SkeletonRows(count: 5, showsBadge: false)
                    .padding(PbRadius.Metrics.spacing24)
                    .readingColumn()
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                feed.pbFadeIn()
            }
        }
    }

    private var feed: some View {
        ActivityFeedView(rows: model.activityRows, start: model.start, history: model.history,
                         isLoading: model.isLoading, tailValue: ActivityFeedTail(liveStep: model.liveStep, pendingMessages: model.pendingMessages,
                            children: model.subTaskStrip?.children.map { TaskDetailTimelineChild(task: $0.task, title: $0.title) } ?? []),
                         paginationRevision: model.paginationRevision, emptyText: model.emptyText, horizontalPadding: PbRadius.Metrics.spacing24,
                         state: state, onLoadMore: model.onLoadMore,
                         tailPresentation: .standard(.init(
                            subTaskStrip: model.subTaskStrip.map { strip in
                                .init(children: strip.children.map { TaskDetailTimelineChild(task: $0.task, title: $0.title) }, start: strip.start)
                            },
                            pendingMessages: model.pendingMessages,
                            liveStep: model.liveStep.map { .init(text: $0.text, indicator: .singleDot) }
                         )), onSelectChildTask: model.onSelectTask ?? model.subTaskStrip?.onSelectTask)
        .readingColumn()
    }
}

// MARK: - SubTaskEntry

/// A child task plus its already-resolved title (`AppModel.title(_:)`'s fallback rule), so this
/// dumb component never has to look one up itself.
struct SubTaskEntry: Identifiable {
    let task: TaskInfo
    let title: String
    var id: String { task.taskID }
}

// MARK: - SubTaskStripModel

struct SubTaskStripModel {
    let children: [SubTaskEntry]
    let start: Date?
    let onSelectTask: (String) -> Void
}

// MARK: - SubTaskStripView

struct SubTaskStripView: View {
    let model: SubTaskStripModel

    var body: some View {
        ActivityCard {
            VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
                Text("Started \(model.children.count) sub-task\(model.children.count == 1 ? "" : "s") via polybridge")
                    .font(.pb(.body, weight: .medium))
                    .monospacedDigit()
                ForEach(model.children) { entry in
                    Button {
                        model.onSelectTask(entry.task.taskID)
                    } label: {
                        HStack(spacing: PbRadius.Metrics.spacing8) {
                            StatusIcon(status: entry.task.status)
                            BackendLabel(backend: entry.task.backend)
                            Text(entry.title).lineLimit(1)
                            if let freedom = entry.task.freedom {
                                Text(AccessLabel.text(freedom: freedom)).foregroundStyle(Color.secondaryText).lineLimit(1)
                            }
                            Spacer()
                            Text(Format.offset(entry.task.startedAt, from: model.start))
                                .monospacedDigit()
                                .foregroundStyle(Color.secondaryText)
                            Image(systemName: "chevron.right").foregroundStyle(Color.secondaryText)
                        }
                        .font(.pb(.secondary))
                        .padding(PbRadius.Metrics.spacing8)
                        .background(RoundedRectangle(cornerRadius: PbRadius.row).fill(Color.pillFill))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

#if DEBUG
@MainActor
private func previewPane(_ model: TimelinePaneModel) -> some View {
    TimelinePaneView(model: model)
        .frame(width: PbRadius.Metrics.timelinePanePreviewWidth, height: PbRadius.Metrics.taskDetailPreviewHeight)
        .background(Color.windowBG)
}

private func previewChild(_ status: String, backend: String = "codex") -> SubTaskEntry {
    let task = TaskInfo(.object([
        "task_id": .string("child-\(status)"), "backend": .string(backend), "status": .string(status),
        "freedom": .string("read_only"), "started_at": .string(ISO8601DateFormatter().string(from: .now.addingTimeInterval(-60)))
    ]))!
    return SubTaskEntry(task: task, title: "Review the keychain change")
}

@MainActor
private var runningModel: TimelinePaneModel {
    TimelinePaneModel(
        stepCountText: "12 steps", rows: PreviewFixtures.sampleRows(running: true), start: .now.addingTimeInterval(-90),
        emptyText: nil,
        subTaskStrip: SubTaskStripModel(
            children: [previewChild("running"), previewChild("completed")], start: .now.addingTimeInterval(-90), onSelectTask: { _ in }
        ),
        isLoading: false
    )
}

@MainActor
private var finishedModel: TimelinePaneModel {
    TimelinePaneModel(
        stepCountText: "12 steps", rows: PreviewFixtures.sampleRows(running: false), start: .now.addingTimeInterval(-90),
        emptyText: nil, subTaskStrip: nil, isLoading: false
    )
}

@MainActor
private var followUpModel: TimelinePaneModel {
    let first = PreviewFixtures.sampleRows(taskID: "t1", running: false)
    let follow = ConversationTimelineRow(
        id: "sep:t2", taskID: "t2", timestamp: .now, kind: .separator(text: "Also add a test for the edge case"), live: false
    )
    let reply = PreviewFixtures.row(PreviewFixtures.textItem("Adding the regression test now.", seq: 1), taskID: "t2", live: true)
    return TimelinePaneModel(
        stepCountText: "13 steps", rows: first + [follow, reply], start: .now.addingTimeInterval(-90), emptyText: nil, subTaskStrip: nil, isLoading: false
    )
}

/// A conversation whose turns recorded prose only: the header shows the steps and conversation
/// turns plus the proven "No tool calls recorded" note (§4).
@MainActor
private var proseOnlyModel: TimelinePaneModel {
    let rows = [PreviewFixtures.row(PreviewFixtures.textItem("Looked at the failing test."), taskID: "t1", live: false)]
    let liveStep = LiveStep(rows: rows)
    return TimelinePaneModel(
        stepCountText: "3 steps", turnsText: "2 turns", noToolCallsText: "No tool calls recorded",
        rows: rows, activityRows: ActivityRowsBuilder.build(from: rows), start: .now.addingTimeInterval(-90),
        emptyText: nil, subTaskStrip: nil, isLoading: false, liveStep: liveStep,
        updateToken: ActivityUpdateToken(rows: rows, liveStep: liveStep)
    )
}

#Preview("Running - light") { previewPane(runningModel).preferredColorScheme(.light) }
#Preview("Running - dark") { previewPane(runningModel).preferredColorScheme(.dark) }
#Preview("Finished - light") { previewPane(finishedModel).preferredColorScheme(.light) }
#Preview("Finished - dark") { previewPane(finishedModel).preferredColorScheme(.dark) }
#Preview("With a follow-up turn - light") { previewPane(followUpModel).preferredColorScheme(.light) }
#Preview("With a follow-up turn - dark") { previewPane(followUpModel).preferredColorScheme(.dark) }
#Preview("Prose only, no tools - light") { previewPane(proseOnlyModel).preferredColorScheme(.light) }
#Preview("Prose only, no tools - dark") { previewPane(proseOnlyModel).preferredColorScheme(.dark) }

#Preview("Sub-task strip - light") {
    SubTaskStripView(model: SubTaskStripModel(children: [previewChild("running"), previewChild("failed")], start: .now, onSelectTask: { _ in }))
        .frame(width: PbRadius.Metrics.taskDetailNarrowPreviewWidth)
.preferredColorScheme(.light)
}

#Preview("Sub-task strip - dark") {
    SubTaskStripView(model: SubTaskStripModel(children: [previewChild("running"), previewChild("failed")], start: .now, onSelectTask: { _ in }))
        .frame(width: PbRadius.Metrics.taskDetailNarrowPreviewWidth)
.preferredColorScheme(.dark)
}

#Preview("Loading - light") {
    previewPane(TimelinePaneModel(stepCountText: nil, rows: [], start: nil, emptyText: nil, subTaskStrip: nil, isLoading: true))
        .preferredColorScheme(.light)
}

#Preview("Loading - dark") {
    previewPane(TimelinePaneModel(stepCountText: nil, rows: [], start: nil, emptyText: nil, subTaskStrip: nil, isLoading: true))
        .preferredColorScheme(.dark)
}

@MainActor
private func historyPreview(complete: Bool) -> some View {
    previewPane(TimelinePaneModel(stepCountText: nil, noToolCallsText: complete ? "No tool calls recorded" : nil,
        rows: [], activityRows: [], start: nil,
        emptyText: complete ? nil : "This task's event log is empty or was not found.", subTaskStrip: nil,
        isLoading: false, liveStep: nil, updateToken: ActivityUpdateToken(rows: [], liveStep: nil),
        history: complete ? EventHistoryState() : EventHistoryState(hasMore: true, error: "Synthetic history read error")))
}

#Preview("Complete empty history - light") { historyPreview(complete: true).preferredColorScheme(.light) }
#Preview("Complete empty history - dark") { historyPreview(complete: true).preferredColorScheme(.dark) }
#Preview("History unavailable, retry - light") { historyPreview(complete: false).preferredColorScheme(.light) }
#Preview("History unavailable, retry - dark") { historyPreview(complete: false).preferredColorScheme(.dark) }
#endif
