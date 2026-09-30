//
//  TimelineRow.swift
//  MainWindowFeature
//
//  A dumb Model + View pair for one timeline row, shared by the Parallel screen and TaskDetail's
//  Activity feed (which render everything but tool cards through it). No offset gutter; a started
//  row carries the prompt as a bubble.
//

import MonitorCore
import PbUI
import SwiftUI

// MARK: - TimelineRowModel

/// Presentation data for one timeline row: the raw `TimelineItem` plus the context its rendering
/// needs (`start`, the conversation's first turn; `live`, for a running tool's spinner).
struct TimelineRowModel: Identifiable {
    let item: TimelineItem
    let start: Date?
    let live: Bool
    /// Whether the started row carries the initial prompt as a bubble. The task feed owns the prompt
    /// this way; a Parallel column shows it only on demand, from its own "View prompt" toggle.
    var showsPromptBubble = true

    var id: Int { item.id }
}

// MARK: - TimelineRow

/// A single timeline row. Dumb component — no logic beyond layout.
struct TimelineRow: View {
    let model: TimelineRowModel

    var body: some View {
        rowBody.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var rowBody: some View {
        switch model.item.body {
        case .started(let started):
            VStack(alignment: .leading, spacing: 10) {
                if model.showsPromptBubble, !started.prompt.isEmpty {
                    PromptBubbleView(text: started.prompt)
                }
                StartLineView(backend: started.backend, time: model.item.at, freedom: started.freedom)
            }
        case .text(let text, let streaming):
            VStack(alignment: .leading, spacing: 2) {
                ReadingMarkdownView(text: text)
                if streaming {
                    if model.live {
                        StreamingCaret()
                    } else {
                        Text("(incomplete)").font(.pb(.caption)).foregroundStyle(Color.secondaryText)
                    }
                }
            }
        case .tool(let call, let result):
            ActivityCard { ToolRow(model: ToolRowModel(call: call, result: result, live: model.live)) }
        case .message(let text, let source):
            PromptBubbleView(text: text, caption: Self.messageCaption(source: source))
        case .notice(let text):
            ActivityNoticeView(text: text, systemImage: "info.circle")
        case .undelivered(let text, let reason):
            ActivityNoticeView(
                text: "Not delivered: \(text ?? "message")" + (reason.map { " — \($0)" } ?? ""),
                systemImage: "exclamationmark.triangle", style: .warning
            )
        case .finished(let status, let exitCode, _):
            ActivityNoticeView(
                text: Self.finishedText(status: TaskStatus(status), exitCode: exitCode),
                systemImage: StatusIcon.symbolName(for: TaskStatus(status)) ?? "flag.checkered",
                style: .finished(TaskStatus(status))
            )
        }
    }

    /// The end-of-run marker: "Finished" for a clean completion; otherwise the status, with the exit
    /// code only when it is non-zero ("Failed · exit 1").
    nonisolated static func finishedText(status: TaskStatus, exitCode: Int?) -> String {
        let base = status == .completed ? "Finished" : status.label
        guard let exitCode, exitCode != 0 else { return base }
        return "\(base) · exit \(exitCode)"
    }

    /// The initial prompt needs no caption; other messages say where they came from.
    static func messageCaption(source: String?) -> String? {
        switch source {
        case "initial": nil
        case "injected": "Message sent to the task"
        default: "User message"
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
            .foregroundStyle(Color.secondaryText)
            .opacity(visible ? 1 : 0.2)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    visible.toggle()
                }
            }
    }
}

#if DEBUG
private struct TimelineRowPreview: View {
    var body: some View {
        let start = Date.now.addingTimeInterval(-30)
        VStack(alignment: .leading, spacing: 12) {
            row(PreviewFixtures.startedItem(prompt: "Fix the flaky login test."), start: start)
            row(PreviewFixtures.textItem("Looked at the failing test."), start: start)
            row(PreviewFixtures.messageItem("Also cover the cold keychain.", source: "injected", seq: 3), start: start)
            row(PreviewFixtures.noticeItem("Context was compacted.", seq: 4), start: start)
            row(PreviewFixtures.editItem(path: "/repo/A.swift", old: "let a = 1", new: "let a = 2", seq: 5), start: start)
            row(PreviewFixtures.finishedItem(), start: start)
        }
        .padding()
        .frame(width: 440)
        .background(Color.windowBG)
    }

    private func row(_ item: TimelineItem, start: Date) -> some View {
        TimelineRow(model: TimelineRowModel(item: item, start: start, live: false))
    }
}

#Preview("Timeline row - light") { TimelineRowPreview().preferredColorScheme(.light) }
#Preview("Timeline row - dark") { TimelineRowPreview().preferredColorScheme(.dark) }
#endif
