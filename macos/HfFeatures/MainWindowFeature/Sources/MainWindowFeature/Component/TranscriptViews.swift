//
//  TranscriptViews.swift
//  MainWindowFeature
//
//  Small views for the task transcript style (`ActivityFeedStyle.transcript`): the tool head's hover
//  plate and the working row's running glyph. Metrics come from `TaskScreenStyle`.
//

import HfUI
import SwiftUI

// MARK: - TranscriptToolHeadPlate

/// `.hd-tool__head`: 28 pt minimum height, `3 6` padding, `13/18` `text-secondary`, a hover plate that
/// bleeds 6 pt outside the text column (`margin: 0 -6px`) and turns the text to `text`.
private struct TranscriptToolHeadPlate: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .font(.hf(.body))
            .foregroundStyle(hovering ? TaskScreenStyle.ToolHead.hoverColor.color : TaskScreenStyle.ToolHead.color.color)
            .padding(.vertical, TaskScreenStyle.ToolHead.paddingVertical)
            .padding(.horizontal, TaskScreenStyle.ToolHead.paddingHorizontal)
            .frame(maxWidth: .infinity, minHeight: TaskScreenStyle.ToolHead.minHeight, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: TaskScreenStyle.ToolHead.hoverCornerRadius)
                .fill(hovering ? TaskScreenStyle.ToolHead.hoverFill.color : Color.clear))
            .padding(.horizontal, -TaskScreenStyle.ToolHead.horizontalBleed)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// The transcript tool head's plate, for a row that renders in `ActivityFeedStyle.transcript`.
    func transcriptToolHeadPlate() -> some View { modifier(TranscriptToolHeadPlate()) }
}

// MARK: - TranscriptWorkingGlyph

/// `.hd-glyph--running`: a 14 pt glyph with a 2 pt `accent-subtle` ring and an `accent` leading arc,
/// turning once a second, inside a 1 pt margin. The arc holds still under Reduce Motion, from the
/// system setting or the presentation-only override.
struct TranscriptWorkingGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hfReduceMotionOverride) private var reduceMotionOverride

    private var reduceMotion: Bool {
        HfMotion.reduceMotion(override: reduceMotionOverride, system: systemReduceMotion)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let turns = reduceMotion ? 0 : context.date
.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: TaskScreenStyle.Working.spinDuration) / TaskScreenStyle.Working.spinDuration
            ZStack {
                Circle().stroke(TaskScreenStyle.Working.glyphRing.color, lineWidth: TaskScreenStyle.Working.glyphRingWidth)
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(TaskScreenStyle.Working.glyphArc.color,
                            style: StrokeStyle(lineWidth: TaskScreenStyle.Working.glyphRingWidth, lineCap: .round))
                    .rotationEffect(.degrees(turns * 360))
            }
        }
        .padding(TaskScreenStyle.Working.glyphMargin)
        .frame(width: TaskScreenStyle.Working.glyphSize + 2 * TaskScreenStyle.Working.glyphMargin,
               height: TaskScreenStyle.Working.glyphSize + 2 * TaskScreenStyle.Working.glyphMargin)
        .accessibilityHidden(true)
    }
}

#if DEBUG
private struct TranscriptViewsPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: TaskScreenStyle.Transcript.gap) {
            HStack(spacing: TaskScreenStyle.Working.gap) {
                TranscriptWorkingGlyph()
                Text("Running tests…").font(.hf(.body)).foregroundStyle(TaskScreenStyle.Working.color.color)
            }
            HStack {
                Image(systemName: "terminal")
                Text("Ran pytest")
                Spacer()
            }
            .transcriptToolHeadPlate()
        }
        .padding(TaskScreenStyle.Transcript.paddingHorizontal)
        .frame(width: HfRadius.Metrics.taskComponentPreviewWidth)
        .background(TaskScreenStyle.Colors.pageBackground.color)
    }
}

#Preview("Transcript views - light") { TranscriptViewsPreview().preferredColorScheme(.light) }
#Preview("Transcript views - dark") { TranscriptViewsPreview().preferredColorScheme(.dark) }
#endif
