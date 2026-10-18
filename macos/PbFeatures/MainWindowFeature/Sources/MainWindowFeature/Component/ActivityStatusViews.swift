//
//  ActivityStatusViews.swift
//  MainWindowFeature
//
//  The quiet lines of the Activity feed: the start line, notices, undelivered messages, the finished
//  marker and the live step.
//

import MonitorCore
import PbUI
import SwiftUI

// MARK: - StartLineView

/// "● Claude started [Can edit this repo] … 10:48" (§6.2): the agent dot, the sentence, the
/// access pill and the start time on the right with tabular digits — every value the old single
/// sentence carried, re-laid-out. `text(backend:time:freedom:)` still produces the whole sentence
/// for VoiceOver, so nothing is lost to accessibility.
struct StartLineView: View {
    let backend: String?
    let time: Date?
    let freedom: String?

    /// The sentence without its dot.
    static func text(backend: String?, time: Date?, freedom: String?) -> String {
        let name = backend.map(BackendStyle.displayName) ?? "Task"
        var text = "\(name) started"
        if let time { text += " at \(Format.time(time))" }
        if let freedom { text += " · \(AccessLabel.text(freedom: freedom))" }
        return text
    }

    private var startedText: String {
        let name = backend.map(BackendStyle.displayName) ?? "Task"
        return "\(name) started"
    }

    var body: some View {
        HStack(spacing: PbRadius.Metrics.spacing6) {
            BackendDot(backend: backend ?? "")
            Text(startedText)
            if let freedom {
                Text(AccessLabel.text(freedom: freedom))
                    .padding(.horizontal, PbRadius.Metrics.spacing6)
                    .padding(.vertical, PbRadius.Metrics.spacing2)
                    .background(Capsule().fill(Color.pillFill))
            }
            Spacer(minLength: PbRadius.Metrics.zero)
            if let time {
                Text(Format.time(time)).monospacedDigit().foregroundStyle(Color.tertiaryText)
            }
        }
        .font(.pb(.secondary))
        .foregroundStyle(Color.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.text(backend: backend, time: time, freedom: freedom))
    }
}

// MARK: - ActivityNoticeView

/// A notice, an undelivered message or the finished marker, as a small pill.
struct ActivityNoticeView: View {
    enum Style {
        case info
        case warning
        case finished(TaskStatus)
    }

    let text: String
    let systemImage: String
    var style: Style = .info

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PbRadius.Metrics.spacing6) {
            Image(systemName: systemImage)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.pb(.secondary, weight: isProminent ? .medium : .regular))
        .foregroundStyle(tint)
        .padding(.horizontal, PbRadius.Metrics.spacing12)
        .padding(.vertical, PbRadius.Metrics.spacing6)
        .background(RoundedRectangle(cornerRadius: PbRadius.row).fill(Color.pillFill))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var isProminent: Bool {
        if case .finished = style { return true }
        return false
    }

    private var tint: Color {
        switch style {
        case .info: Color.secondaryText
        case .warning: Color.failedRed
        case .finished(let status): StatusColor.of(status)
        }
    }
}

// MARK: - LiveStepLineView

/// A pulsing dot and the current step. It sits under the feed and owns nothing. The pulse follows
/// Reduce Motion dynamically — the presentation-only override wins over the system setting, and a
/// change mid-flight stops or restarts the pulse without waiting for a re-mount.
///
/// The `threeDots` indicator is the Parallel lane variant (§6.5): three `liveDot` dots and the step
/// text in tertiary text, shown only when the lane's existing `LiveStep` says real work is
/// happening. The default `singleDot` keeps every other consumer's presentation unchanged.
struct LiveStepLineView: View {
    enum Indicator: Hashable {
        /// The shared default: one pulsing `liveDot` dot, secondary text.
        case singleDot
        /// The Parallel lane variant: three pulsing `liveDot` dots, tertiary text.
        case threeDots
    }

    let text: String
    var indicator: Indicator = .singleDot
    @State private var isDimmed = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.pbReduceMotionOverride) private var reduceMotionOverride

    private var reduceMotion: Bool {
        PbMotion.reduceMotion(override: reduceMotionOverride, system: systemReduceMotion)
    }

    var body: some View {
        HStack(spacing: PbRadius.Metrics.spacing8) {
            dots
            Text(text)
                .font(.pb(.secondary))
                .foregroundStyle(indicator == .threeDots ? Color.tertiaryText : Color.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { updatePulse() }
        .onChange(of: reduceMotion) { _, _ in updatePulse() }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var dots: some View {
        switch indicator {
        case .singleDot:
            // The shared default keeps its exact 8 pt dot, so TaskDetail's timeline is unchanged.
            Circle()
                .fill(Color.liveDot)
                .frame(width: PbRadius.Metrics.spacing8, height: PbRadius.Metrics.spacing8)
                .opacity(isDimmed ? 0.3 : 1)
                .accessibilityHidden(true)
        case .threeDots:
            HStack(spacing: PbRadius.Metrics.liveIndicatorDotSpacing) {
                dot
                dot
                dot
            }
        }
    }

    private var dot: some View {
        Circle()
            .fill(Color.liveDot)
            .frame(width: PbRadius.Metrics.liveIndicatorDotSize, height: PbRadius.Metrics.liveIndicatorDotSize)
            .opacity(isDimmed ? 0.3 : 1)
            .accessibilityHidden(true)
    }

    /// Starts the pulse unless Reduce Motion is active, and settles the dot at full opacity when it
    /// is — an arriving or re-resolved pulse never leaves the dot dimmed.
    private func updatePulse() {
        if reduceMotion {
            withAnimation(.none) { isDimmed = false }
            return
        }
        guard !isDimmed else { return }
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { isDimmed = true }
    }
}

#if DEBUG
private struct ActivityStatusPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing10) {
            StartLineView(backend: "vibe", time: .now, freedom: "write_in_repo")
            ActivityNoticeView(text: "Context was compacted.", systemImage: "info.circle")
            ActivityNoticeView(text: "Not delivered: hello — the run had already ended", systemImage: "exclamationmark.triangle", style: .warning)
            ActivityNoticeView(text: "Finished", systemImage: "checkmark.circle.fill", style: .finished(.completed))
            ActivityNoticeView(text: "Failed · exit 1", systemImage: "xmark.circle.fill", style: .finished(.failed))
            LiveStepLineView(text: "Reading AppDelegate.swift…")
            LiveStepLineView(text: "Running 2 tests…", indicator: .threeDots)
        }
        .padding(PbRadius.Metrics.spacing16)
        .frame(width: PbRadius.Metrics.taskDetailNarrowPreviewWidth)
        .background(Color.windowBG)
    }
}

#Preview("Status lines - light") { ActivityStatusPreview().preferredColorScheme(.light) }
#Preview("Status lines - dark") { ActivityStatusPreview().preferredColorScheme(.dark) }

#Preview("Status lines, Reduce Motion - light") {
    ActivityStatusPreview().environment(\.pbReduceMotionOverride, true).preferredColorScheme(.light)
}

#Preview("Status lines, Reduce Motion - dark") {
    ActivityStatusPreview().environment(\.pbReduceMotionOverride, true).preferredColorScheme(.dark)
}
#endif
