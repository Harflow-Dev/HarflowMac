//
//  TurnSeparatorRow.swift
//  MainWindowFeature
//
//  A follow-up's own prompt and time, ahead of its turn. Shared by TaskDetail's `TimelinePaneView`
//  and the Parallel screen's `ParallelColumnView`, both of which render a `ConversationTimelineRow`.
//

import HfUI
import MonitorCore
import SwiftUI

// MARK: - TurnSeparatorRow

/// A follow-up's own prompt and time, ahead of its turn (settled Design point 6): a right-aligned
/// bubble captioned "You · 14:02".
struct TurnSeparatorRow: View {
    let text: String
    let timestamp: Date?
    @Environment(\.activityFeedStyle) private var feedStyle

    static func caption(timestamp: Date?) -> String {
        "You" + (timestamp.map { " · \(Format.time($0))" } ?? "")
    }

    static func label(text: String, timestamp: Date?) -> String {
        caption(timestamp: timestamp) + " — " + text
    }

    var body: some View {
        if feedStyle.isTranscript {
            transcriptBody
        } else {
            PromptBubbleView(text: text, caption: Self.caption(timestamp: timestamp))
                .padding(.top, 8)
        }
    }

    /// `.hd-turn-sep`: the caption centred between two 1 pt rules, then the follow-up as a user bubble.
    private var transcriptBody: some View {
        VStack(alignment: .leading, spacing: TaskScreenStyle.TurnSeparator.gap) {
            TurnSeparatorDivider(label: Self.caption(timestamp: timestamp))
            PromptBubbleView(text: text)
        }
    }
}

// MARK: - TurnSeparatorDivider

/// `.hd-turn-sep`: the label centred between two 1 pt rules. Shared by the follow-up separator and the Summary entry.
struct TurnSeparatorDivider: View {
    let label: String

    var body: some View {
        HStack(spacing: TaskScreenStyle.TurnSeparator.gap) {
            rule
            Text(label)
                .font(.hf(.secondary))
                .frame(height: TaskScreenStyle.TurnSeparator.text.lineHeight)
                .foregroundStyle(TaskScreenStyle.TurnSeparator.color.color)
                .fixedSize()
            rule
        }
    }

    private var rule: some View {
        Rectangle()
            .fill(TaskScreenStyle.TurnSeparator.ruleColor.color)
            .frame(height: TaskScreenStyle.TurnSeparator.ruleThickness)
    }
}

#if DEBUG
private struct TurnSeparatorPreview: View {
    var body: some View {
        TurnSeparatorRow(text: "Also add a test for the edge case", timestamp: .now)
            .padding()
            .frame(width: 440)
            .background(Color.windowBG)
    }
}

#Preview("Turn separator - light") { TurnSeparatorPreview().preferredColorScheme(.light) }
#Preview("Turn separator - dark") { TurnSeparatorPreview().preferredColorScheme(.dark) }
#endif
