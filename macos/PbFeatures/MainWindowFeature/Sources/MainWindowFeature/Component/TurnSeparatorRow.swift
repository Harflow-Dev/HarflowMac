//
//  TurnSeparatorRow.swift
//  MainWindowFeature
//
//  Moved out of `TaskDetail/Component/TimelinePaneView.swift` (Monitor piece 13) to sit alongside
//  `TimelineRow.swift`/`ToolRow.swift` — it is now shared by TaskDetail's own `TimelinePaneView` and
//  the Parallel screen's `ParallelColumnView`, both of which render a `ConversationTimelineRow`.
//

import MonitorCore
import PbUI
import SwiftUI

// MARK: - TurnSeparatorRow

/// A follow-up's own prompt and time, ahead of its turn (settled Design point 6): "You · 14:02 —
/// <message>".
struct TurnSeparatorRow: View {
    let text: String
    let timestamp: Date?

    static func label(text: String, timestamp: Date?) -> String {
        "You" + (timestamp.map { " · \(Format.time($0))" } ?? "") + " — " + text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text("You" + (timestamp.map { " · \(Format.time($0))" } ?? ""))
                    .font(.pb(.secondary, weight: .semibold))
                    .foregroundStyle(Color.accentLink)
                Text(text).font(.pb(.body)).textSelection(.enabled)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.runningBG.opacity(0.6)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.label(text: text, timestamp: timestamp))
        }
        .padding(.vertical, 6)
    }
}

#if DEBUG
#Preview {
    TurnSeparatorRow(text: "Also add a test for the edge case", timestamp: .now)
        .padding()
        .frame(width: 400)
}
#endif
