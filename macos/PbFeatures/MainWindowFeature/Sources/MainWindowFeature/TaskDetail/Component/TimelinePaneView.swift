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
    let stepCountText: String
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
    let onLoadMore: (() -> Void)?

    init(
        stepCountText: String, rows: [ConversationTimelineRow], activityRows: [ActivityRow], start: Date?, emptyText: String?,
        subTaskStrip: SubTaskStripModel?, isLoading: Bool, liveStep: LiveStep?, updateToken: ActivityUpdateToken,
        pendingMessages: [PendingMessage] = [], history: EventHistoryState = EventHistoryState(), onLoadMore: (() -> Void)? = nil
    ) {
        self.stepCountText = stepCountText
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
        self.onLoadMore = onLoadMore
    }

    /// Derives the feed rows, live step and update token from `rows` — for previews and tests; the
    /// VM builds them itself in `recomputeTimeline`.
    init(stepCountText: String, rows: [ConversationTimelineRow], start: Date?, emptyText: String?, subTaskStrip: SubTaskStripModel?, isLoading: Bool) {
        let liveStep = LiveStep(rows: rows)
        self.init(
            stepCountText: stepCountText, rows: rows, activityRows: ActivityRowsBuilder.build(from: rows), start: start,
            emptyText: emptyText, subTaskStrip: subTaskStrip, isLoading: isLoading, liveStep: liveStep,
            updateToken: ActivityUpdateToken(rows: rows, liveStep: liveStep)
        )
    }

    @MainActor
    static let empty = TimelinePaneModel(stepCountText: "0 steps", rows: [], start: nil, emptyText: nil, subTaskStrip: nil, isLoading: false)
}

// MARK: - TimelinePaneView

struct TimelinePaneView: View {
    let model: TimelinePaneModel
    @State private var followLive = FollowLiveScrollState()
    @State private var olderAnchor: String?
    @State private var expandedGroups: Set<String> = []
    @State private var seenRowIDs: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.stepCountText).font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .readingColumn()
            if model.isLoading, model.liveStep == nil {
                SkeletonRows(count: 5, showsBadge: false)
                    .padding(24)
                    .readingColumn()
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                feed.pbFadeIn()
            }
        }
    }

    private var feed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if let onLoadMore = model.onLoadMore, model.history.hasMore || model.history.error != nil {
                        Button {
                            followLive.suspend()
                            olderAnchor = model.activityRows.first?.id
                            onLoadMore()
                        } label: {
                            if model.history.isLoading {
                                LoadingLabel("Loading activity…")
                            } else {
                                Text(model.history.error == nil ? "Load more activity" : "Retry older activity")
                                    .font(.pb(.secondary))
.frame(minHeight: 20)
                            }
                        }
.buttonStyle(.plain)
.disabled(model.history.isLoading)
                        if let error = model.history.error { Text(error).font(.pb(.secondary)) }
                    } else if !model.rows.isEmpty {
                        Text("Beginning of loaded activity").font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
                    }
                    if let emptyText = model.emptyText {
                        Text(emptyText).font(.pb(.body)).foregroundStyle(Color.secondaryText)
                    }
                    ForEach(model.activityRows) { row in
                        rowView(row)
.id(row.id)
                            .pbFadeIn(animate: !seenRowIDs.contains(row.id))
                            .onAppear { seenRowIDs.insert(row.id) }
                    }
                    if let subTaskStrip = model.subTaskStrip {
                        SubTaskStripView(model: subTaskStrip)
                    }
                    ForEach(model.pendingMessages) { message in
                        PromptBubbleView(text: message.text, caption: "Pending", isPending: true)
                    }
                    if let liveStep = model.liveStep {
                        LiveStepLineView(text: liveStep.text)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(24)
                .readingColumn()
                .background(LiveScrollPositionObserver { offset, contentHeight, viewportHeight in
                    guard olderAnchor == nil else { return }
                    followLive.observe(offset: offset, contentHeight: contentHeight, viewportHeight: viewportHeight)
                })
            }
            .followLiveScroll(token: model.updateToken, enabled: followLive.isFollowing && olderAnchor == nil, proxy: proxy, target: "bottom")
            .onChange(of: model.activityRows.first?.id) { _, _ in
                if let olderAnchor { proxy.scrollTo(olderAnchor, anchor: .top); self.olderAnchor = nil }
            }
            .onChange(of: model.history.isLoading) { _, loading in
                if !loading, let olderAnchor { proxy.scrollTo(olderAnchor, anchor: .top); self.olderAnchor = nil }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: ActivityRow) -> some View {
        switch row {
        case .toolGroup(let group):
            ToolGroupCardView(group: group, start: model.start, isExpanded: expandedGroups.contains(group.id)) {
                withAnimation(PbMotion.disclosure(reduceMotion: reduceMotion)) {
                    if !expandedGroups.insert(group.id).inserted { expandedGroups.remove(group.id) }
                }
            }
        case .single(let row):
            switch row.kind {
            case .separator(let text):
                TurnSeparatorRow(text: text, timestamp: row.timestamp)
            case .item(let item):
                TimelineRow(model: TimelineRowModel(item: item, start: model.start, live: row.live))
            }
        }
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
            VStack(alignment: .leading, spacing: 8) {
                Text("Started \(model.children.count) sub-task\(model.children.count == 1 ? "" : "s") via polybridge")
                    .font(.pb(.body, weight: .medium))
                ForEach(model.children) { entry in
                    Button {
                        model.onSelectTask(entry.task.taskID)
                    } label: {
                        HStack(spacing: 8) {
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
                        .padding(8)
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
        .frame(width: 640, height: 620)
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

#Preview("Running - light") { previewPane(runningModel).preferredColorScheme(.light) }
#Preview("Running - dark") { previewPane(runningModel).preferredColorScheme(.dark) }
#Preview("Finished - light") { previewPane(finishedModel).preferredColorScheme(.light) }
#Preview("Finished - dark") { previewPane(finishedModel).preferredColorScheme(.dark) }
#Preview("With a follow-up turn - light") { previewPane(followUpModel).preferredColorScheme(.light) }
#Preview("With a follow-up turn - dark") { previewPane(followUpModel).preferredColorScheme(.dark) }

#Preview("Loading - light") {
    previewPane(TimelinePaneModel(stepCountText: "0 steps", rows: [], start: nil, emptyText: nil, subTaskStrip: nil, isLoading: true))
        .preferredColorScheme(.light)
}

#Preview("Loading - dark") {
    previewPane(TimelinePaneModel(stepCountText: "0 steps", rows: [], start: nil, emptyText: nil, subTaskStrip: nil, isLoading: true))
        .preferredColorScheme(.dark)
}
#endif
