//
//  ParallelColumnView.swift
//  MainWindowFeature
//
//  Dumb component: a Model plus two action closures the VM supplies; the "show all" and tool-card
//  expansion are local `@State`, allowed per the root AGENTS.md's Component Models section
//  ("components may hold local @State").
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
    /// How many activity rows a column shows before "Show all N steps".
    static let windowSize = 6

    let id: String
    let task: TaskInfo
    let title: String
    /// "<repo name> · <Backend>", plus "· N turns" once the conversation has more than one turn.
    let subtitle: String
    let isBusy: Bool
    let outcomeMessage: String?
    let showPrompt: Bool
    let prompt: String?
    /// The raw rows, one per timeline item (and separator) — what the "Show all N steps" count reads.
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
    /// From the current member's snapshot only — no fallback to `task.summary` (F4-40, a deliberate
    /// difference from `ChangesPane`).
    let summary: String?
    let onTapTakeover: () -> Void
    let onTapOpenTask: () -> Void
    /// When the conversation's FIRST turn started — every row's elapsed time counts from here, as
    /// TaskDetail's Timeline does; the current turn's own start would clamp earlier turns to 0.
    var start: Date?

    /// "<repo name> · <Backend>" plus "· N turns" when `turns > 1` — the task header's subtitle,
    /// without the session id.
    static func subtitle(repoPath: String, backend: String, turns: Int) -> String {
        var parts = [Format.repoName(repoPath), BackendStyle.displayName(backend)].filter { !$0.isEmpty }
        if turns > 1 { parts.append("\(turns) turns") }
        return parts.joined(separator: " · ")
    }

    /// The last `windowSize` activity rows, or all of them once "Show all" has been tapped. A pure
    /// function so it is directly testable without a SwiftUI rendering harness. Counting rows
    /// (separators and tool cards included) rather than items keeps the newest turn separator in
    /// view naturally, without a special case.
    static func visibleRows(_ rows: [ActivityRow], showAll: Bool) -> [ActivityRow] {
        showAll ? rows : Array(rows.suffix(windowSize))
    }

    /// The real step count behind `rows` — every `.item` row, separators excluded — for the "Show
    /// all N steps" label, matching `TimelinePaneModel`'s own `stepCountText` convention.
    static func itemCount(_ rows: [ConversationTimelineRow]) -> Int {
        rows.filter { if case .item = $0.kind { return true }; return false }.count
    }
}

// MARK: - ParallelColumnView

struct ParallelColumnView: View {
    let model: ParallelColumnModel
    @State private var showAll = false
    @State private var expandedGroups: Set<String> = []
    @State private var followLive = true

    var body: some View {
        let shown = ParallelColumnModel.visibleRows(model.activityRows, showAll: showAll)
        VStack(alignment: .leading, spacing: 10) {
            header
            if let message = model.outcomeMessage {
                Text(message).font(.pb(.caption)).foregroundStyle(Color.secondaryText)
            }
            if model.showPrompt, let prompt = model.prompt {
                PromptBubbleView(text: prompt)
            }
            Divider()
            if model.isLoading, model.liveStep == nil {
                SkeletonRows(count: 4, showsBadge: false)
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                feed(shown)
            }
        }
        .padding(16)
        .opensFileLinks(repoPath: model.task.repoPath)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                StatusIcon(status: model.task.status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title).font(.pb(.body, weight: .semibold)).lineLimit(2)
                    Text(model.subtitle).font(.pb(.caption)).foregroundStyle(Color.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 8)
                TaskStatusLabel(task: model.task).fixedSize()
            }
            HStack(spacing: 10) {
                if model.isBusy { ProgressView().controlSize(.small) }
                if WorkflowNodePresentation.allowsTerminal(model.task) {
                Button(model.task.status.isRunning ? "Take over" : "Continue in terminal") { model.onTapTakeover() }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(model.task.sessionID == nil || model.isBusy)
                }
                Button("Open task") { model.onTapOpenTask() }.buttonStyle(.link)
            }
            .font(.pb(.secondary))
        }
    }

    // MARK: Feed

    private func feed(_ shown: [ActivityRow]) -> some View {
        VStack(spacing: 8) {
            // Same row as the task feed: step count, and a follow toggle that keeps the column at
            // its newest step while the agent works.
            HStack {
                Text("\(ParallelColumnModel.itemCount(model.rows)) steps").font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
                Spacer()
                Toggle("Follow live", isOn: $followLive).toggleStyle(.checkbox).font(.pb(.secondary))
            }
            ScrollViewReader { proxy in
                scrollingFeed(shown)
                    .followLiveScroll(token: ActivityUpdateToken(rows: model.rows, liveStep: model.liveStep, pendingMessages: model.pendingMessages),
                                      enabled: followLive, proxy: proxy, target: Self.bottomID)
            }
        }
    }

    private static let bottomID = "column-bottom"

    private func scrollingFeed(_ shown: [ActivityRow]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(shown) { row in
                    rowView(row)
                }
                if model.activityRows.count > shown.count {
                    Button("Show all \(ParallelColumnModel.itemCount(model.rows)) steps") { showAll = true }
                        .buttonStyle(.link)
                        .font(.pb(.secondary))
                }
                ForEach(model.pendingMessages) { message in
                    PromptBubbleView(text: message.text, caption: "Pending", isPending: true)
                }
                if let liveStep = model.liveStep {
                    LiveStepLineView(text: liveStep.text)
                }
                Color.clear.frame(height: 1).id(Self.bottomID)
            }
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func rowView(_ row: ActivityRow) -> some View {
        switch row {
        case .toolGroup(let group):
            ToolGroupCardView(group: group, start: model.start, isExpanded: expandedGroups.contains(group.id)) {
                if !expandedGroups.insert(group.id).inserted { expandedGroups.remove(group.id) }
            }
        case .single(let row):
            switch row.kind {
            case .separator(let text):
                TurnSeparatorRow(text: text, timestamp: row.timestamp)
            case .item(let item):
                TimelineRow(model: TimelineRowModel(item: item, start: model.start, live: row.live, showsPromptBubble: false))
            }
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
        .frame(width: 380, height: 560)
        .background(Color.windowBG)
}

@MainActor
private func columnModel(
    id: String = "abc123", task: TaskInfo, rows: [ConversationTimelineRow], isLoading: Bool = false, turns: Int = 1,
    summary: String? = nil
) -> ParallelColumnModel {
    ParallelColumnModel(
        id: id, task: task, title: "Fix the login bug",
        subtitle: ParallelColumnModel.subtitle(repoPath: "/Users/me/Code/polybridge", backend: task.backend, turns: turns),
        isBusy: false, outcomeMessage: nil, showPrompt: false, prompt: nil,
        rows: rows, activityRows: ActivityRowsBuilder.build(from: rows), liveStep: LiveStep(rows: rows), isLoading: isLoading,
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
#endif
