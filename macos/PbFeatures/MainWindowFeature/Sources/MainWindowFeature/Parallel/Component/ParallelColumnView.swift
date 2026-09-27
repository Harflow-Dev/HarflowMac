//
//  ParallelColumnView.swift
//  MainWindowFeature
//
//  Ported from the app target's `ParallelView.swift` (`ParallelColumn`). Dumb component: a Model
//  plus two action closures the VM supplies; the "show all" expansion is local `@State`, allowed
//  per the root AGENTS.md's Component Models section ("components may hold local @State").
//

import MonitorCore
import PbUI
import SwiftUI

// MARK: - ParallelColumnModel

/// Presentation data for one Parallel column: the member's fresh listing entry, everything today's
/// outcome line/busy state/event stream say about it, and the two actions its buttons perform.
struct ParallelColumnModel: Identifiable {
    let id: String
    let task: TaskInfo
    let title: String
    let metaLine: String
    let isBusy: Bool
    let outcomeMessage: String?
    let showPrompt: Bool
    let prompt: String?
    let items: [TimelineItem]
    /// True while this member has no timeline items yet AND its event stream is still `.loading`
    /// (Monitor piece 12, Design point 4) — the column shows `SkeletonRows` instead of the empty
    /// timeline while this holds.
    let isLoading: Bool
    /// From the snapshot only — no fallback to `task.summary` (F4-40, a deliberate difference from
    /// `ChangesPane`).
    let summary: String?
    let onTapTakeover: () -> Void
    let onTapOpenTask: () -> Void
    
    /// The last 6 items, or all of them once "Show all" has been tapped. A pure function so it is
    /// directly testable without a SwiftUI rendering harness.
    static func visibleItems(_ items: [TimelineItem], showAll: Bool) -> [TimelineItem] {
        showAll ? items : Array(items.suffix(6))
    }
}

// MARK: - ParallelColumnView

struct ParallelColumnView: View {
    let model: ParallelColumnModel
    @State private var showAll = false
    
    var body: some View {
        let shown = ParallelColumnModel.visibleItems(model.items, showAll: showAll)
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
                        ForEach(shown) { item in
                            TimelineRow(model: TimelineRowModel(item: item, start: model.task.startedAt, live: model.task.status.isRunning))
                        }
                        if model.items.count > shown.count {
                            Button("Show all \(model.items.count) steps") { showAll = true }.buttonStyle(.link).font(.pb(.secondary))
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
        items: [PreviewFixtures.textItem("Looked at the failing test.")], isLoading: false,
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
        items: [], isLoading: true,
        summary: nil, onTapTakeover: {}, onTapOpenTask: {}
    ))
    .frame(width: 380, height: 500)
}
#endif
