//
//  ParallelColumnView.swift
//  MainWindowFeature
//
//  Ported from the app target's `ParallelView.swift` (`ParallelColumn`). Dumb component: a Model
//  plus two action closures the VM supplies; the "show all" expansion is local `@State`, allowed
//  per the root AGENTS.md's Component Models section ("components may hold local @State").
//
//  Monitor piece 13: a column is one agent CONVERSATION (a resume chain), not one task — `rows` is
//  the whole conversation's concatenated timeline (`MonitorCore.ConversationTimeline`, the same
//  shape TaskDetail's own `TimelinePaneView` renders), with a turn separator ahead of every
//  follow-up and each row's own `live` flag already scoped to its own turn.
//

import MonitorCore
import PbUI
import SwiftUI

// MARK: - ParallelColumnModel

/// Presentation data for one Parallel column: the conversation's fresh CURRENT member (status pill,
/// take-over, buttons all act on it), everything today's outcome line/busy state/event stream say
/// about it, and the two actions its buttons perform.
struct ParallelColumnModel: Identifiable {
    let id: String
    let task: TaskInfo
    let title: String
    let metaLine: String
    let isBusy: Bool
    let outcomeMessage: String?
    let showPrompt: Bool
    let prompt: String?
    let rows: [ConversationTimelineRow]
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

    /// The last 6 rows, or all of them once "Show all" has been tapped. A pure function so it is
    /// directly testable without a SwiftUI rendering harness. Counting rows (separators included)
    /// rather than items keeps the newest turn separator in view naturally, without a special case.
    static func visibleRows(_ rows: [ConversationTimelineRow], showAll: Bool) -> [ConversationTimelineRow] {
        showAll ? rows : Array(rows.suffix(6))
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

    var body: some View {
        let shown = ParallelColumnModel.visibleRows(model.rows, showAll: showAll)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                BackendBadge(backend: model.task.backend, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title).font(.pb(.body, weight: .semibold)).lineLimit(2)
                    Text(model.metaLine).font(.pb(.caption)).foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(task: model.task)
            }
            HStack {
                Button(model.task.status.isRunning ? "Take over" : "Continue in terminal") { model.onTapTakeover() }
                    .disabled(model.task.sessionID == nil || model.isBusy)
                Button("Open task") { model.onTapOpenTask() }.buttonStyle(.link)
            }
            .font(.pb(.secondary))
            if let message = model.outcomeMessage {
                Text(message).font(.pb(.caption)).foregroundStyle(.secondary)
            }
            if model.showPrompt, let prompt = model.prompt {
                Text(prompt)
                    .font(.pb(.secondary, design: .monospaced))
                    .lineLimit(12)
                    .textSelection(.enabled)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.codeFill))
            }
            Divider()
            if model.isLoading {
                SkeletonRows(count: 4, showsBadge: false)
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(shown) { row in
                            rowView(row)
                        }
                        if model.rows.count > shown.count {
                            Button("Show all \(ParallelColumnModel.itemCount(model.rows)) steps") { showAll = true }
                                .buttonStyle(.link)
.font(.pb(.secondary))
                        }
                        Divider()
                        if model.task.status.isTerminal {
                            SectionLabel(text: "Final summary")
                            if let summary = model.summary, !summary.isEmpty {
                                MarkdownText(text: summary)
                            } else {
                                Text("No summary was reported.").font(.pb(.body)).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Still working… the final summary shows here when \(model.task.backend) finishes.")
                                .font(.pb(.body))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func rowView(_ row: ConversationTimelineRow) -> some View {
        switch row.kind {
        case .separator(let text):
            TurnSeparatorRow(text: text, timestamp: row.timestamp)
        case .item(let item):
            TimelineRow(model: TimelineRowModel(item: item, start: model.start, live: row.live))
        }
    }
}

#if DEBUG
#Preview {
    let task = TaskInfo(.object([
        "task_id": .string("abc123"), "backend": .string("claude"), "status": .string("running"),
        "started_at": .string(ISO8601DateFormatter().string(from: .now.addingTimeInterval(-90)))
    ]))!
    ParallelColumnView(model: ParallelColumnModel(
        id: "abc123", task: task, title: "Fix the login bug", metaLine: "claude · effort low",
        isBusy: false, outcomeMessage: nil, showPrompt: false, prompt: nil,
        rows: [
            ConversationTimelineRow(
                id: "abc123#1", taskID: "abc123", timestamp: .now,
                kind: .item(PreviewFixtures.textItem("Looked at the failing test.")), live: true
            )
        ],
        isLoading: false,
        summary: nil, onTapTakeover: {}, onTapOpenTask: {}
    ))
    .frame(width: 380, height: 500)
}

#Preview("Loading column") {
    let task = TaskInfo(.object([
        "task_id": .string("abc123"), "backend": .string("claude"), "status": .string("running"),
        "started_at": .string(ISO8601DateFormatter().string(from: .now.addingTimeInterval(-2)))
    ]))!
    ParallelColumnView(model: ParallelColumnModel(
        id: "abc123", task: task, title: "Fix the login bug", metaLine: "claude · effort low",
        isBusy: false, outcomeMessage: nil, showPrompt: false, prompt: nil,
        rows: [], isLoading: true,
        summary: nil, onTapTakeover: {}, onTapOpenTask: {}
    ))
    .frame(width: 380, height: 500)
}

#Preview("With a follow-up turn") {
    let task = TaskInfo(.object([
        "task_id": .string("t2"), "backend": .string("claude"), "status": .string("running"),
        "started_at": .string(ISO8601DateFormatter().string(from: .now.addingTimeInterval(-90)))
    ]))!
    ParallelColumnView(model: ParallelColumnModel(
        id: "t1", task: task, title: "Fix the login bug", metaLine: "claude · effort low · 2 turns",
        isBusy: false, outcomeMessage: nil, showPrompt: false, prompt: nil,
        rows: [
            ConversationTimelineRow(
                id: "t1#1", taskID: "t1", timestamp: .now.addingTimeInterval(-90),
                kind: .item(PreviewFixtures.textItem("Looked at the failing test.")), live: false
            ),
            ConversationTimelineRow(
                id: "sep:t2", taskID: "t2", timestamp: .now,
                kind: .separator(text: "Also add a test for the edge case"), live: false
            ),
            ConversationTimelineRow(id: "t2#1", taskID: "t2", timestamp: .now, kind: .item(PreviewFixtures.finishedItem()), live: true)
        ],
        isLoading: false,
        summary: nil, onTapTakeover: {}, onTapOpenTask: {}
    ))
    .frame(width: 380, height: 500)
}
#endif
