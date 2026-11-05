//
//  ActivityRowsBuilder.swift
//  MainWindowFeature
//
//  A pure, single-pass fold of a conversation's timeline rows into Activity feed rows. It never
//  removes or moves a canonical tool row: every call stays at its own position inside its card,
//  pending or not. `TimelineBuilder` and `ConversationTimeline` (MonitorCore) are untouched.
//

import Foundation
import HfUI
import MonitorCore

// MARK: - ActivityRowsBuilder

enum ActivityRowsBuilder {

    /// Adjacent tool rows of one bucket (and one task) fold into a card. Text, messages, notices,
    /// undelivered notes, finished markers, separators, edits/writes and a task change all close the
    /// open card and stay individual rows.
    ///
    /// Captured historical messages retain their own identity and are never deduplicated by text.
    static func build(from rows: [ConversationTimelineRow], cancellationAware: Bool = false,
                      markdown: [String: StreamingMarkdownState] = [:]) -> [ActivityRow] {
        var result: [ActivityRow] = []
        result.reserveCapacity(rows.count)
        var open: OpenGroup?

        for row in rows {
            if cancellationAware, Task.isCancelled { return [] }
            guard case .item(let item) = row.kind else {
                closeGroup(&open, into: &result)
                result.append(.single(row, markdown: prepared(row, previous: markdown[row.id])))
                continue
            }
            switch item.body {
            case .tool(let call, let resultOfCall):
                guard let bucket = ToolBucket(category: call.category) else {
                    closeGroup(&open, into: &result)
                    result.append(.single(row, markdown: prepared(row, previous: markdown[row.id])))
                    continue
                }
                let member = ToolGroupMember(id: row.id, call: call, result: resultOfCall, timestamp: item.at, live: row.live)
                if open?.bucket == bucket, open?.taskID == row.taskID {
                    open?.members.append(member)
                } else {
                    closeGroup(&open, into: &result)
                    open = OpenGroup(id: row.id, taskID: row.taskID, bucket: bucket, members: [member])
                }
            default:
                closeGroup(&open, into: &result)
                result.append(.single(row, markdown: prepared(row, previous: markdown[row.id])))
            }
        }
        closeGroup(&open, into: &result)
        return result
    }

    static func markdownSnapshot(from rows: [ConversationTimelineRow], previous: [String: StreamingMarkdownState]) -> [String: StreamingMarkdownState] {
        var result: [String: StreamingMarkdownState] = [:]
        for row in rows {
            if let value = prepared(row, previous: previous[row.id]) { result[row.id] = value }
        }
        return result
    }

    private static func prepared(_ row: ConversationTimelineRow, previous: StreamingMarkdownState?) -> StreamingMarkdownState? {
        guard case .item(let item) = row.kind, case .text(let text, let streaming) = item.body else { return nil }
        return (previous ?? StreamingMarkdownState()).updating(text: text, isStreaming: streaming)
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

}
