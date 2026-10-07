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
    /// Minimum recent activity rows; taller cells reveal additional history.
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
    var animatesArrival = false
    var onDidPresent: () -> Void = {}
    var memberTaskIDs: Set<String> = []

    /// "<repo name> · <Backend>" plus "· N turns" when `turns > 1` — the task header's subtitle,
    /// without the session id.
    static func subtitle(repoPath: String, backend: String, turns: Int) -> String {
        var parts = [Format.repoName(repoPath), BackendStyle.displayName(backend)].filter { !$0.isEmpty }
        if turns > 1 { parts.append("\(turns) turns") }
        return parts.joined(separator: " · ")
    }

    /// At least `windowSize` recent rows, growing to fit measured available space; Show all bypasses the window. A pure
    /// function so it is directly testable without a SwiftUI rendering harness. Counting rows
    /// (separators and tool cards included) rather than items keeps the newest turn separator in
    /// view naturally, without a special case.
    static func visibleRows(_ rows: [ActivityRow], showAll: Bool, availableHeight: CGFloat = 0,
                            heights: [String: CGFloat] = [:], retainedFirstID: String? = nil, previousFirstID: String? = nil) -> [ActivityRow] {
        if showAll { return rows }
        if let retainedFirstID, let first = rows.firstIndex(where: { $0.id == retainedFirstID }) {
            return Array(rows[first...])
        }
        // An arriving/rewrapped row has not been measured yet. Keep the established
        // history boundary until its true size is known, rather than briefly pruning it.
        if rows.suffix(windowSize).contains(where: { heights[$0.id] == nil }),
           let previousFirstID, let first = rows.firstIndex(where: { $0.id == previousFirstID }) {
            return Array(rows[first...])
        }
        var count = min(windowSize, rows.count)
        var used = rows.suffix(count).reduce(CGFloat(0)) { $0 + (heights[$1.id] ?? availableHeight) }
            + CGFloat(max(0, count - 1)) * 20
        while count < rows.count {
            let next = rows[rows.count - count - 1]
            guard let height = heights[next.id], used + 20 < availableHeight else { break }
            used += 20 + height
            count += 1
        }
        return Array(rows.suffix(count))
    }

    /// Measure only the next older row, rather than mounting the entire hidden history.
    static func measurementCandidate(_ rows: [ActivityRow], shown: [ActivityRow], availableHeight: CGFloat,
                                     heights: [String: CGFloat]) -> ActivityRow? {
        guard shown.count < rows.count, !shown.isEmpty,
              shown.allSatisfy({ heights[$0.id] != nil }) else { return nil }
        let used = shown.reduce(CGFloat(0)) { $0 + (heights[$1.id] ?? 0) } + CGFloat(shown.count - 1) * 20
        let next = rows[rows.count - shown.count - 1]
        return used + 20 < availableHeight && heights[next.id] == nil ? next : nil
    }

    /// The real step count behind `rows` — every `.item` row, separators excluded — for the "Show
    /// all N steps" label, matching `TimelinePaneModel`'s own `stepCountText` convention.
    static func itemCount(_ rows: [ConversationTimelineRow]) -> Int {
        rows.filter { if case .item = $0.kind { return true }; return false }.count
    }
}

// MARK: - ParallelRowMeasurement

struct ParallelRowMeasurement: Equatable {
    let size: CGSize
    let viewportWidth: CGFloat
}

// MARK: - ParallelColumnScrollKey

struct ParallelColumnScrollKey: Equatable {
    let rowIDs: [String]
    let viewport: CGSize
}

// MARK: - ParallelColumnView

struct ParallelColumnView: View {
    let model: ParallelColumnModel
    @State private var showAll = false
    @State private var expandedGroups: Set<String> = []
    @State private var seenRowIDs: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followLive = FollowLiveScrollState()
    @State private var rowHeights: [String: CGFloat] = [:]
    @State private var rowWidths: [String: CGFloat] = [:]
    @State private var viewportHeight: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var tailHeight: CGFloat = 0
    @State private var retainedFirstID: String?
    @State private var recentFirstID: String?
    @State private var adaptingToBottom = false

    init(model: ParallelColumnModel) {
        self.model = model
        // Revealing older history is not a new activity arrival.
        _seenRowIDs = State(initialValue: Set(model.activityRows.map(\.id)))
    }

    // The native scroll document can be narrower than its SwiftUI proposal (scroller
    // gutters/rounding). Cache against the proposal used to measure, not that child width.
    private var measuredHeights: [String: CGFloat] {
        rowHeights.filter { abs((rowWidths[$0.key] ?? 0) - viewportWidth) < 1 }
    }

    private var availableHeight: CGFloat { max(0, viewportHeight - tailHeight - 53) }

    var body: some View {
        let shown = ParallelColumnModel.visibleRows(model.activityRows, showAll: showAll, availableHeight: availableHeight,
                                                   heights: measuredHeights, retainedFirstID: retainedFirstID, previousFirstID: recentFirstID)
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
                feed(shown).pbFadeIn()
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .opensFileLinks(repoPath: model.task.repoPath)
        .onChange(of: measuredHeights) { _, _ in
            if !showAll, retainedFirstID == nil, shown.allSatisfy({ measuredHeights[$0.id] != nil }) {
                recentFirstID = shown.first?.id
            }
        }
        .onChange(of: shown.map(\.id)) { _, _ in
            if followLive.isFollowing { adaptingToBottom = true }
            if !showAll, retainedFirstID == nil, shown.allSatisfy({ measuredHeights[$0.id] != nil }) {
                recentFirstID = shown.first?.id
            }
        }
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
                Button("Open task") { model.onTapOpenTask() }.buttonStyle(.link)
                Spacer(minLength: 8)
                if model.isBusy { ProgressView().controlSize(.small) }
                if WorkflowNodePresentation.allowsTerminal(model.task) {
                TerminalActionButton(model.task.status.isRunning ? "Take over" : "Continue in terminal", action: model.onTapTakeover)
                    .disabled(model.task.sessionID == nil || model.isBusy)
                }
            }
            .font(.pb(.secondary))
        }
    }

    // MARK: Feed

    private func feed(_ shown: [ActivityRow]) -> some View {
        VStack(spacing: 8) {
            // Same step count as the task feed; scrolling follows only while at the bottom.
            HStack {
                Text("\(ParallelColumnModel.itemCount(model.rows)) steps").font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
                Spacer()
            }
            ScrollViewReader { proxy in
                GeometryReader { viewport in
                    let measurementWidth = viewport.size.width
                    scrollingFeed(shown, width: viewport.size.width)
                        .frame(width: viewport.size.width, height: viewport.size.height)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                            if followLive.isFollowing,
                               size != CGSize(width: viewportWidth, height: viewportHeight) {
                                adaptingToBottom = true
                            }
                            viewportHeight = size.height
                            viewportWidth = size.width
                        }
                        .overlay(alignment: .topLeading) {
                            if !showAll, retainedFirstID == nil,
                               let candidate = ParallelColumnModel.measurementCandidate(model.activityRows, shown: shown,
                                                                                         availableHeight: availableHeight, heights: measuredHeights) {
                                rowView(candidate)
                                    .frame(width: viewport.size.width, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .onGeometryChange(for: ParallelRowMeasurement.self) {
                                        ParallelRowMeasurement(size: $0.size, viewportWidth: measurementWidth)
                                    } action: { measurement in
                                        rowHeights[candidate.id] = measurement.size.height
                                        rowWidths[candidate.id] = measurement.viewportWidth
                                    }
                                    .onAppear { seenRowIDs.insert(candidate.id) }
                                    .hidden()
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                                    .id(candidate.id)
                            }
                        }
                }
                    .task(id: ParallelColumnScrollKey(rowIDs: shown.map(\.id),
                                                     viewport: CGSize(width: viewportWidth, height: viewportHeight))) {
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        guard followLive.isFollowing else { adaptingToBottom = false; return }
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                        adaptingToBottom = false
                    }
                    .followLiveScroll(token: ActivityUpdateToken(rows: model.rows, liveStep: model.liveStep, pendingMessages: model.pendingMessages),
                                      enabled: followLive.isFollowing, proxy: proxy, target: Self.bottomID)
            }
        }
    }

    private static let bottomID = "column-bottom"

    private func scrollingFeed(_ shown: [ActivityRow], width: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(shown) { row in
                    rowView(row)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: ParallelRowMeasurement.self) {
                            ParallelRowMeasurement(size: $0.size, viewportWidth: width)
                        } action: { measurement in
                            rowHeights[row.id] = measurement.size.height
                            rowWidths[row.id] = measurement.viewportWidth
                        }
                        .pbFadeIn(animate: !seenRowIDs.contains(row.id))
                        .onAppear { seenRowIDs.insert(row.id) }
                }
                VStack(alignment: .leading, spacing: 20) {
                    if model.activityRows.count > ParallelColumnModel.windowSize, !showAll {
                        Button("Show all \(ParallelColumnModel.itemCount(model.rows)) steps") {
                            followLive.suspend()
                            withAnimation(PbMotion.disclosure(reduceMotion: reduceMotion)) { showAll = true }
                        }
                        .buttonStyle(.link)
                        .font(.pb(.secondary))
                        // Reserve this slot while adapting so removing the button cannot
                        // alternate between two different history windows.
                        .opacity(model.activityRows.count > shown.count ? 1 : 0)
                        .disabled(model.activityRows.count <= shown.count)
                        .accessibilityHidden(model.activityRows.count <= shown.count)
                    }
                    ForEach(model.pendingMessages) { message in
                        PromptBubbleView(text: message.text, caption: "Pending", isPending: true)
                    }
                    if let liveStep = model.liveStep {
                        LiveStepLineView(text: liveStep.text)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tailHeight = $0 }
                Color.clear.frame(height: 1).id(Self.bottomID)
            }
            .padding(.bottom, 12)
            .background(LiveScrollPositionObserver { offset, contentHeight, viewportHeight in
                if adaptingToBottom {
                    // Native layout can report a temporary upward offset while history is
                    // prepended. Keep the bottom baseline until scroll restoration completes.
                    followLive.observe(offset: max(0, contentHeight - viewportHeight),
                                       contentHeight: contentHeight, viewportHeight: viewportHeight)
                    return
                }
                let wasFollowing = followLive.isFollowing
                followLive.observe(offset: offset, contentHeight: contentHeight, viewportHeight: viewportHeight)
                if wasFollowing, !followLive.isFollowing { retainedFirstID = shown.first?.id }
                if followLive.isFollowing { retainedFirstID = nil }
            })
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
