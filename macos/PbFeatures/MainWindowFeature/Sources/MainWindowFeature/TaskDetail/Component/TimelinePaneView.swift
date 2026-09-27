//
//  TimelinePaneView.swift
//  MainWindowFeature
//
//  Ported from the app target's `TimelineViews.swift` (`TimelinePane`, `SubTaskStrip`). Follow-live
//  defaults to on and stays local `@State` per the screen shape's own allowance — the VM never owns
//  it. Reuses the package-root `TimelineRow`/`TimelineRowModel` shared with the Parallel screen.
//
//  Monitor piece 7: `rows` is the whole conversation's concatenated timeline
//  (`MonitorCore.ConversationTimelineRow` — a globally unique id across every member, since
//  `TimelineItem.id` alone restarts per member/task), with a turn separator ahead of every
//  follow-up. Per-row `live` already reflects which turn is the current, running one (Review
//  round 1, item 1), so no separate `live` flag is needed at the pane level any more.
//

import MonitorCore
import PbUI
import SwiftUI

// MARK: - TimelinePaneModel

struct TimelinePaneModel {
    let stepCountText: String
    let rows: [ConversationTimelineRow]
    let start: Date?
    let emptyText: String?
    let subTaskStrip: SubTaskStripModel?

    @MainActor
    static let empty = TimelinePaneModel(stepCountText: "0 steps", rows: [], start: nil, emptyText: nil, subTaskStrip: nil)

    /// Row count alone misses a streamed reply growing inside the *last* row without adding a new
    /// one (Review round 1, item 5) — combined with that row's own content length, growth of
    /// either kind re-triggers Follow live's scroll. Row identity itself (`row.id`) stays stable
    /// across a growing stream: only the text inside an existing row changes, never its id. A pure
    /// function, so it is directly testable without a SwiftUI rendering harness (the same reasoning
    /// as `ParallelColumnModel.visibleItems`).
    static func scrollTrigger(for rows: [ConversationTimelineRow]) -> String {
        guard let last = rows.last else { return "0" }
        var length = 0
        if case .item(let item) = last.kind, case .text(let text, _) = item.body { length = text.count }
        return "\(rows.count)|\(last.id)|\(length)"
    }
}

// MARK: - TimelinePaneView

struct TimelinePaneView: View {
    let model: TimelinePaneModel
    @State private var followLive = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.stepCountText).font(.pb(.secondary)).foregroundStyle(.secondary)
                Spacer()
                Toggle("Follow live", isOn: $followLive).toggleStyle(.checkbox).font(.pb(.secondary))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if let emptyText = model.emptyText {
                            Text(emptyText).font(.pb(.body)).foregroundStyle(.secondary)
                        }
                        ForEach(model.rows) { row in
                            rowView(row).id(row.id)
                        }
                        if let subTaskStrip = model.subTaskStrip {
                            SubTaskStripView(model: subTaskStrip)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(14)
                }
                .onChange(of: TimelinePaneModel.scrollTrigger(for: model.rows)) { _, _ in
                    if followLive { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
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

// MARK: - TurnSeparatorRow

/// A follow-up's own prompt and time, ahead of its turn (settled Design point 6): "You · 14:02 —
/// <message>".
struct TurnSeparatorRow: View {
    let text: String
    let timestamp: Date?

    static func label(text: String, timestamp: Date?) -> String {
        "You" + (timestamp.map { " · \(Format.time($0))" } ?? "") + " — " + text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text("You" + (timestamp.map { " · \(Format.time($0))" } ?? ""))
                    .font(.pb(.secondary, weight: .semibold))
                    .foregroundStyle(Color.accentLink)
                Text(text).font(.pb(.body)).textSelection(.enabled)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.runningBG.opacity(0.6)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.label(text: text, timestamp: timestamp))
        }
        .padding(.vertical, 6)
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Started \(model.children.count) sub-task\(model.children.count == 1 ? "" : "s") via polybridge").font(.pb(.body, weight: .medium))
            ForEach(model.children) { entry in
                Button {
                    model.onSelectTask(entry.task.taskID)
                } label: {
                    HStack(spacing: 8) {
                        BackendBadge(backend: entry.task.backend, size: 18)
                        Text(entry.title).lineLimit(1)
                        FreedomBadge(freedom: entry.task.freedom)
                        Spacer()
                        Text(entry.task.status.label).foregroundStyle(StatusColor.of(entry.task.status))
                        Text(Format.offset(entry.task.startedAt, from: model.start)).monospacedDigit().foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .font(.pb(.secondary))
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(Color.hairline))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#if DEBUG
#Preview {
    let start = Date.now.addingTimeInterval(-30)
    TimelinePaneView(model: TimelinePaneModel(
        stepCountText: "2 steps",
        rows: [
            ConversationTimelineRow(
                id: "t#1", taskID: "t", timestamp: start, kind: .item(PreviewFixtures.textItem("Looked at the failing test.")), live: false
            ),
            ConversationTimelineRow(id: "t#2", taskID: "t", timestamp: start, kind: .item(PreviewFixtures.finishedItem()), live: false)
        ],
        start: start, emptyText: nil, subTaskStrip: nil
    ))
    .frame(width: 500, height: 400)
}

#Preview("With a follow-up turn") {
    let start = Date.now.addingTimeInterval(-90)
    TimelinePaneView(model: TimelinePaneModel(
        stepCountText: "2 steps",
        rows: [
            ConversationTimelineRow(
                id: "t1#1", taskID: "t1", timestamp: start, kind: .item(PreviewFixtures.textItem("Looked at the failing test.")), live: false
            ),
            ConversationTimelineRow(
                id: "sep:t2", taskID: "t2", timestamp: start.addingTimeInterval(60),
                kind: .separator(text: "Also add a test for the edge case"), live: false
            ),
            ConversationTimelineRow(id: "t2#1", taskID: "t2", timestamp: start.addingTimeInterval(60), kind: .item(PreviewFixtures.finishedItem()), live: false)
        ],
        start: start, emptyText: nil, subTaskStrip: nil
    ))
    .frame(width: 500, height: 400)
}
#endif
