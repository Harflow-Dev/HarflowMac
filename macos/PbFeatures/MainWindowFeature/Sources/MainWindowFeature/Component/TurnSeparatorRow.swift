//
//  TurnSeparatorRow.swift
//  MainWindowFeature
//
//  A follow-up's own prompt and time, ahead of its turn. Shared by TaskDetail's `TimelinePaneView`
//  and the Parallel screen's `ParallelColumnView`, both of which render a `ConversationTimelineRow`.
//

import MonitorCore
import PbUI
import SwiftUI

// MARK: - TurnSeparatorRow

/// A follow-up's own prompt and time, ahead of its turn (settled Design point 6): a right-aligned
/// bubble captioned "You · 14:02".
struct TurnSeparatorRow: View {
    let text: String
    let timestamp: Date?

    static func caption(timestamp: Date?) -> String {
        "You" + (timestamp.map { " · \(Format.time($0))" } ?? "")
    }

    static func label(text: String, timestamp: Date?) -> String {
        caption(timestamp: timestamp) + " — " + text
    }

    var body: some View {
        PromptBubbleView(text: text, caption: Self.caption(timestamp: timestamp))
            .padding(.top, 8)
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
