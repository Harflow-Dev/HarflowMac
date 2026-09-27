//
//  TimelineRow.swift
//  MainWindowFeature
//
//  A dumb Model + View pair for one timeline row, shared by the Parallel screen and (eventually,
//  Phase 4d) TaskDetail. Ported byte-for-byte from the app target's `TimelineViews.swift`
//  (`TimelineRow`) — the old copy stays there untouched for TaskDetail's own use until it migrates
//  (this dispatch's own AGENTS.md / the phase-4 brief's scope line).
//

import MonitorCore
import PbUI
import SwiftUI

// MARK: - TimelineRowModel

/// Presentation data for one timeline row: the raw `TimelineItem` plus the two pieces of context
/// its rendering needs (`start`, for the leading time offset; `live`, for a running tool's spinner).
struct TimelineRowModel: Identifiable {
    let item: TimelineItem
    let start: Date?
    let live: Bool
    
    var id: Int { item.id }
}

// MARK: - TimelineRow

/// A single timeline row. Dumb component — no logic beyond layout, ported unchanged from the old
/// `TimelineViews.swift`.
struct TimelineRow: View {
    let model: TimelineRowModel
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(Format.offset(model.item.at, from: model.start))
                .font(.pb(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            rowBody
            Spacer(minLength: 0)
        }
    }
    
    @ViewBuilder
    private var rowBody: some View {
        switch model.item.body {
        case .started(let started):
            VStack(alignment: .leading, spacing: 2) {
                Text("Started" + (started.spawnedBy != nil ? " by another task via polybridge" : " via polybridge")).font(.pb(.body, weight: .medium))
                Text([started.backend, started.freedom, started.reasoningEffort.map { "effort \($0)" }].compactMap(\.self).joined(separator: " · "))
                    .font(.pb(.secondary))
                    .foregroundStyle(.secondary)
            }
        case .text(let text, let streaming):
            VStack(alignment: .leading, spacing: 2) {
                MarkdownText(text: text)
                if streaming {
                    if model.live {
                        StreamingCaret()
                    } else {
                        Text("(incomplete)").font(.pb(.caption)).foregroundStyle(.secondary)
                    }
                }
            }
        case .tool(let call, let result):
            ToolRow(model: ToolRowModel(call: call, result: result, live: model.live))
        case .message(let text, let source):
            VStack(alignment: .leading, spacing: 2) {
                Text(source == "injected" ? "Message sent to the task" : (source == "initial" ? "Prompt" : "User message"))
                    .font(.pb(.secondary, weight: .semibold))
                    .foregroundStyle(Color.accentLink)
                Text(text).font(.pb(.body)).lineLimit(source == "initial" ? 6 : nil).textSelection(.enabled)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.runningBG.opacity(0.6)))
        case .notice(let text):
            Label(text, systemImage: "info.circle").font(.pb(.secondary)).foregroundStyle(.secondary)
        case .undelivered(let text, let reason):
            Label("Not delivered: \(text ?? "message")" + (reason.map { " — \($0)" } ?? ""), systemImage: "exclamationmark.triangle")
                .font(.pb(.secondary))
                .foregroundStyle(Color.failedRed)
        case .finished(let status, let exitCode, _):
            let color = StatusColor.of(TaskStatus(status))
            Label("Finished: \(TaskStatus(status).label)" + (exitCode.map { " · exit \($0)" } ?? ""), systemImage: "flag.checkered")
                .font(.pb(.body, weight: .medium))
                .foregroundStyle(color)
        }
    }
}

// MARK: - StreamingCaret

/// A subtle blinking caret shown after an in-progress streamed assistant reply, only while its turn
/// is actually running (Review round 1, item 6).
struct StreamingCaret: View {
    @State private var visible = true

    var body: some View {
        Text("▍")
            .font(.pb(.body, design: .monospaced))
            .foregroundStyle(.secondary)
            .opacity(visible ? 1 : 0.2)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    visible.toggle()
                }
            }
    }
}

#if DEBUG
#Preview {
    let start = Date.now.addingTimeInterval(-30)
    VStack(alignment: .leading, spacing: 10) {
        TimelineRow(model: TimelineRowModel(item: PreviewFixtures.textItem("Looked at the failing test."), start: start, live: false))
        TimelineRow(model: TimelineRowModel(item: PreviewFixtures.finishedItem(), start: start, live: false))
    }
    .padding()
    .frame(width: 360)
}
#endif
