//
//  TimelineRow.swift
//  MainWindowFeature
//
//  A dumb Model + View pair for one timeline row, shared by the Parallel screen and TaskDetail's
//  Activity feed (which renders everything but tool cards through it). The two differ only by
//  `TimelineRowStyle`: the feed has no offset gutter and shows a started row's prompt as a bubble;
//  a Parallel column keeps its narrow gutter and leaves the prompt to the column's own toggle.
//

import MonitorCore
import PbUI
import SwiftUI

// MARK: - TimelineRowStyle

enum TimelineRowStyle {
    /// The Activity tab: no offset gutter, the started row carries the prompt bubble.
    case feed
    /// A Parallel column: an elapsed-time gutter, no prompt bubble on the started row.
    case column
}

// MARK: - TimelineRowModel

/// Presentation data for one timeline row: the raw `TimelineItem` plus the context its rendering
/// needs (`start`, for the leading time offset; `live`, for a running tool's spinner).
struct TimelineRowModel: Identifiable {
    let item: TimelineItem
    let start: Date?
    let live: Bool
    var style: TimelineRowStyle = .column

    var id: Int { item.id }
}

// MARK: - TimelineRow

/// A single timeline row. Dumb component — no logic beyond layout.
struct TimelineRow: View {
    let model: TimelineRowModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if model.style == .column {
                Text(Format.offset(model.item.at, from: model.start))
                    .font(.pb(.caption, design: .monospaced))
                    .foregroundStyle(Color.secondaryText)
                    .frame(width: 44, alignment: .trailing)
            }
            rowBody.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var rowBody: some View {
        switch model.item.body {
        case .started(let started):
            VStack(alignment: .leading, spacing: 10) {
                if model.style == .feed, !started.prompt.isEmpty {
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
            let row = ToolRow(model: ToolRowModel(call: call, result: result, live: model.live))
            if model.style == .feed { ActivityCard { row } } else { row }
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
                text: "Finished: \(TaskStatus(status).label)" + (exitCode.map { " · exit \($0)" } ?? ""),
                systemImage: "flag.checkered", style: .finished(TaskStatus(status))
            )
        }
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
    let style: TimelineRowStyle

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
        TimelineRow(model: TimelineRowModel(item: item, start: start, live: false, style: style))
    }
}

#Preview("Timeline row (feed) - light") { TimelineRowPreview(style: .feed).preferredColorScheme(.light) }
#Preview("Timeline row (feed) - dark") { TimelineRowPreview(style: .feed).preferredColorScheme(.dark) }
#Preview("Timeline row (column) - light") { TimelineRowPreview(style: .column).preferredColorScheme(.light) }
#Preview("Timeline row (column) - dark") { TimelineRowPreview(style: .column).preferredColorScheme(.dark) }
#endif
