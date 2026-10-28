//
//  TimelineRow.swift
//  MainWindowFeature
//
//  A dumb Model + View pair for one timeline row, shared by the Parallel screen and TaskDetail's
//  Activity feed (which render everything but tool cards through it). No offset gutter; a started
//  row carries the prompt as a bubble.
//

import HfUI
import MonitorCore
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

    var markdown: StreamingMarkdownState?

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
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing10) {
                if model.showsPromptBubble, !started.prompt.isEmpty {
                    PromptBubbleView(text: started.prompt)
                }
                StartLineView(backend: started.backend, time: model.item.at, freedom: started.freedom)
            }
        case .text(let text, let streaming):
            preparedText(text)
                .padding(.bottom, HfRadius.Metrics.spacing16)
                .overlay(alignment: .bottomLeading) {
                    if streaming {
                        if model.live {
                            StreamingCaret()
                        } else {
                            Text("(incomplete)").font(.hf(.caption)).foregroundStyle(Color.secondaryText)
                        }
                    }
                }
        case .tool(let call, let result):
            GroupedActivityCard {
                ActivityCardRow {
                    ToolRow(model: ToolRowModel(call: call, result: result, live: model.live))
                }
            }
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
            finishedMarker(status: TaskStatus(status), exitCode: exitCode)
        }
    }

    @ViewBuilder
    private func preparedText(_ text: String) -> some View {
        if let markdown = model.markdown {
            ReadingMarkdownView(text: text, prepared: markdown)
        } else {
            // Unprepared compatibility rows have deterministic geometry in native measurement.
            Text(text)
.font(.hf(.reading))
.lineSpacing(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    /// The end-of-run marker (§6.2): the truthful status/exit text centred between hairlines —
    /// "Finished" for a clean completion, otherwise the status with the exit code only when it is
    /// non-zero. No duration: the per-member finished item supplies no reliably paired start, so
    /// the Summary headline and header badge own the settled duration, not this row.
    private func finishedMarker(status: TaskStatus, exitCode: Int?) -> some View {
        HStack(spacing: HfRadius.Metrics.spacing12) {
            Rectangle().fill(Color.hairline).frame(height: HfRadius.Metrics.hairlineStroke)
            HStack(spacing: HfRadius.Metrics.spacing6) {
                Image(systemName: StatusIcon.symbolName(for: status) ?? "flag.checkered")
                    .accessibilityHidden(true)
                Text(Self.finishedText(status: status, exitCode: exitCode)).monospacedDigit()
            }
            .font(.hf(.secondary, weight: .medium))
            .foregroundStyle(StatusColor.of(status))
            .padding(.vertical, HfRadius.Metrics.spacing10)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            Rectangle().fill(Color.hairline).frame(height: HfRadius.Metrics.hairlineStroke)
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
/// is actually running (Review round 1, item 6). The blink follows Reduce Motion dynamically — the
/// presentation-only override wins over the system setting, and a change mid-flight stops or
/// restarts it without waiting for a re-mount.
struct StreamingCaret: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hfReduceMotionOverride) private var reduceMotionOverride

    private var reduceMotion: Bool {
        HfMotion.reduceMotion(override: reduceMotionOverride, system: systemReduceMotion)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            Text("▍")
                .font(.hf(.body, design: .monospaced))
                .foregroundStyle(Color.secondaryText)
                .opacity(reduceMotion ? 1 : Self.opacity(at: context.date))
        }
    }

    /// A 1.2 second cycle matches the former 0.6 second autoreversing blink. The clock
    /// belongs to this tiny leaf, keeping its ticks out of the selectable text's transaction.
    static func opacity(at date: Date) -> Double {
        0.6 + 0.4 * cos(date.timeIntervalSinceReferenceDate * 2 * .pi / 1.2)
    }
}

#if DEBUG
private struct TimelineRowPreview: View {
    var body: some View {
        let start = Date.now.addingTimeInterval(-30)
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing12) {
            row(PreviewFixtures.startedItem(prompt: "Fix the flaky login test."), start: start)
            row(PreviewFixtures.textItem("Looked at the failing test."), start: start)
            row(PreviewFixtures.messageItem("Also cover the cold keychain.", source: "injected", seq: 3), start: start)
            row(PreviewFixtures.noticeItem("Context was compacted.", seq: 4), start: start)
            row(PreviewFixtures.editItem(path: "/repo/A.swift", old: "let a = 1", new: "let a = 2", seq: 5), start: start)
            row(PreviewFixtures.finishedItem(), start: start)
        }
        .padding(HfRadius.Metrics.spacing16)
        .frame(width: HfRadius.Metrics.timelineRowPreviewWidth)
        .background(Color.windowBG)
    }

    private func row(_ item: TimelineItem, start: Date) -> some View {
        TimelineRow(model: TimelineRowModel(item: item, start: start, live: false))
    }
}

#Preview("Timeline row - light") { TimelineRowPreview().preferredColorScheme(.light) }
#Preview("Timeline row - dark") { TimelineRowPreview().preferredColorScheme(.dark) }

#Preview("Streaming caret - light") {
    StreamingCaret().environment(\.hfReduceMotionOverride, false).preferredColorScheme(.light)
}

#Preview("Streaming caret - dark") {
    StreamingCaret().environment(\.hfReduceMotionOverride, false).preferredColorScheme(.dark)
}

#Preview("Streaming caret, Reduce Motion - light") {
    StreamingCaret().environment(\.hfReduceMotionOverride, true).preferredColorScheme(.light)
}

#Preview("Streaming caret, Reduce Motion - dark") {
    StreamingCaret().environment(\.hfReduceMotionOverride, true).preferredColorScheme(.dark)
}
#endif
