//
//  LiveStep.swift
//  MainWindowFeature
//
//  The Activity feed's "what is it doing right now" line. It is an additional indicator read from
//  `Timeline.current`: it owns nothing, and the pending call stays in place inside its card.
//

import Foundation
import MonitorCore

// MARK: - LiveStep

struct LiveStep: Equatable, Sendable {
    let text: String

    /// The latest tool call still waiting for its result in the running turn; `nil` for a terminal
    /// task (its unresolved calls keep reading "no result") and when nothing is pending.
    init?(rows: [ConversationTimelineRow], isRunning: Bool = false) {
        let liveItems: [TimelineItem] = rows.compactMap { row in
            guard row.live, case .item(let item) = row.kind else { return nil }
            return item
        }
        if let current = Timeline.current(in: liveItems), case .tool(let call, _) = current.body {
            self.text = Self.text(for: call)
        } else if isRunning, !liveItems.contains(where: { if case .text(_, streaming: true) = $0.body { return true }; return false }) {
            self.text = "Thinking…"
        } else { return nil }
    }

    /// "Reading <file>…", "Running <command>…", else "<tool>…".
    static func text(for call: TaskEvent.ToolCall) -> String {
        switch call.category {
        case "read":
            let name = call.path.flatMap { $0.isEmpty ? nil : ($0 as NSString).lastPathComponent }
            return "Reading \(name ?? clipped(call.headline))…"
        case "shell":
            return "Running \(clipped(call.command ?? call.headline))…"
        default:
            return "\(call.tool)…"
        }
    }

    private static func clipped(_ text: String, limit: Int = 80) -> String {
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? text
        return String(firstLine.prefix(limit))
    }
}
