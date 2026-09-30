//
//  ActivityRowsBuilder.swift
//  MainWindowFeature
//
//  A pure, single-pass fold of a conversation's timeline rows into Activity feed rows. It never
//  removes or moves a canonical tool row: every call stays at its own position inside its card,
//  pending or not. `TimelineBuilder` and `ConversationTimeline` (MonitorCore) are untouched.
//

import Foundation
import MonitorCore

// MARK: - ActivityRowsBuilder

enum ActivityRowsBuilder {

    /// Adjacent tool rows of one bucket (and one task) fold into a card. Text, messages, notices,
    /// undelivered notes, finished markers, separators, edits/writes and a task change all close the
    /// open card and stay individual rows.
    ///
    /// The initial prompt is rendered once, from `task_started.prompt` (`TimelineRow` shows the started row's prompt as a bubble): only
    /// the matching `user_message(source: "initial")` of the first member is dropped here, so a
    /// mid-run message that happens to repeat the prompt still shows.
    static func build(from rows: [ConversationTimelineRow]) -> [ActivityRow] {
        var result: [ActivityRow] = []
        result.reserveCapacity(rows.count)
        var open: OpenGroup?
        let initial = InitialPrompt(rows)
        var initialSuppressed = false

        for row in rows {
            guard case .item(let item) = row.kind else {
                closeGroup(&open, into: &result)
                result.append(.single(row))
                continue
            }
            switch item.body {
            case .tool(let call, let resultOfCall):
                guard let bucket = ToolBucket(category: call.category) else {
                    closeGroup(&open, into: &result)
                    result.append(.single(row))
                    continue
                }
                let member = ToolGroupMember(id: row.id, call: call, result: resultOfCall, timestamp: item.at, live: row.live)
                if open?.bucket == bucket, open?.taskID == row.taskID {
                    open?.members.append(member)
                } else {
                    closeGroup(&open, into: &result)
                    open = OpenGroup(id: row.id, taskID: row.taskID, bucket: bucket, members: [member])
                }
            case .message(let text, let source):
                closeGroup(&open, into: &result)
                if !initialSuppressed, initial.matches(row, text: text, source: source) {
                    initialSuppressed = true
                    continue
                }
                result.append(.single(row))
            default:
                closeGroup(&open, into: &result)
                result.append(.single(row))
            }
        }
        closeGroup(&open, into: &result)
        return result
    }

    // MARK: - Open group

    private struct OpenGroup {
        let id: String
        let taskID: String
        let bucket: ToolBucket
        var members: [ToolGroupMember]
    }

    private static func closeGroup(_ open: inout OpenGroup?, into result: inout [ActivityRow]) {
        guard let group = open else { return }
        result.append(.toolGroup(ToolGroup(id: group.id, taskID: group.taskID, bucket: group.bucket, members: group.members)))
        open = nil
    }

    // MARK: - Initial prompt

    /// The first member's `task_started.prompt`, found among that member's own leading rows. Absent
    /// when the conversation does not open with its first member's rows, or that member has no
    /// `started` row: then nothing is suppressed, so the initial message is the one bubble.
    private struct InitialPrompt {
        let taskID: String?
        let prompt: String?

        init(_ rows: [ConversationTimelineRow]) {
            guard let first = rows.first, case .item = first.kind else {
                self.taskID = nil
                self.prompt = nil
                return
            }
            self.taskID = first.taskID
            var found: String?
            for row in rows {
                guard row.taskID == first.taskID else { break }
                if case .item(let item) = row.kind, case .started(let started) = item.body {
                    found = started.prompt
                    break
                }
            }
            self.prompt = found
        }

        func matches(_ row: ConversationTimelineRow, text: String, source: String?) -> Bool {
            source == "initial" && row.taskID == taskID && text == prompt
        }
    }
}
