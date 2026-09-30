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

/// "● Vibe started at 10:48 · Can edit this repo".
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

    var body: some View {
        HStack(spacing: 6) {
            BackendDot(backend: backend ?? "")
            Text(Self.text(backend: backend, time: time, freedom: freedom))
        }
        .font(.pb(.secondary))
        .foregroundStyle(Color.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.pb(.secondary, weight: isProminent ? .medium : .regular))
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.pillFill))
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

/// A pulsing dot and the current step. It sits under the feed and owns nothing.
struct LiveStepLineView: View {
    let text: String
    @State private var isDimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.liveDot)
                .frame(width: 8, height: 8)
                .opacity(isDimmed ? 0.3 : 1)
                .accessibilityHidden(true)
            Text(text)
                .font(.pb(.secondary))
                .foregroundStyle(Color.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { isDimmed = true }
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
private struct ActivityStatusPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StartLineView(backend: "vibe", time: .now, freedom: "write_in_repo")
            ActivityNoticeView(text: "Context was compacted.", systemImage: "info.circle")
            ActivityNoticeView(text: "Not delivered: hello — the run had already ended", systemImage: "exclamationmark.triangle", style: .warning)
            ActivityNoticeView(text: "Finished: Done · exit 0", systemImage: "flag.checkered", style: .finished(.completed))
            LiveStepLineView(text: "Reading AppDelegate.swift…")
        }
        .padding()
        .frame(width: 480)
        .background(Color.windowBG)
    }
}

#Preview("Status lines - light") { ActivityStatusPreview().preferredColorScheme(.light) }
#Preview("Status lines - dark") { ActivityStatusPreview().preferredColorScheme(.dark) }
#endif
