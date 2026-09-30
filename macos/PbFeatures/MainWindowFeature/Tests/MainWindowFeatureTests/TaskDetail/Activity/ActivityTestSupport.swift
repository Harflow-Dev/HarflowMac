import Foundation
@testable import MainWindowFeature
@testable import MonitorCore

/// Builds `ConversationTimelineRow`s for the Activity feed tests. `TimelineItem` and its payloads have
/// internal memberwise initialisers, reachable through `@testable import MonitorCore`.
enum ActivityFixture {
    static let base = Date(timeIntervalSince1970: 1_700_000_000)

    static func call(
        _ id: String, tool: String = "Read", category: String = "read", path: String? = nil, command: String? = nil,
        input: String = ""
    ) -> TaskEvent.ToolCall {
        TaskEvent.ToolCall(
            callID: id, tool: tool, category: category, inputPreview: input.isEmpty ? (command ?? path ?? tool) : input,
            path: path, command: command, editOld: nil, editNew: nil
        )
    }

    static func result(_ id: String, ok: Bool = true, exitCode: Int? = nil) -> TaskEvent.ToolResult {
        TaskEvent.ToolResult(callID: id, ok: ok, outputTail: "", exitCode: exitCode)
    }

    static func row(
        _ seq: Int, task: String = "t1", live: Bool = true, at offset: TimeInterval? = nil, _ body: TimelineItem.Body
    ) -> ConversationTimelineRow {
        let time = base.addingTimeInterval(offset ?? TimeInterval(seq))
        return ConversationTimelineRow(
            id: "\(task)#\(seq)", taskID: task, timestamp: time, kind: .item(TimelineItem(id: seq, at: time, body: body)), live: live
        )
    }

    static func tool(
        _ seq: Int, task: String = "t1", category: String = "read", path: String? = nil, command: String? = nil, input: String = "",
        tool name: String? = nil, resolved: Bool = true, ok: Bool = true, live: Bool = true, at offset: TimeInterval? = nil
    ) -> ConversationTimelineRow {
        let id = "c\(seq)"
        let toolCall = call(id, tool: name ?? category.capitalized, category: category, path: path, command: command, input: input)
        return row(seq, task: task, live: live, at: offset, .tool(toolCall, resolved ? result(id, ok: ok) : nil))
    }

    static func text(_ seq: Int, _ text: String = "thinking", task: String = "t1", streaming: Bool = false) -> ConversationTimelineRow {
        row(seq, task: task, .text(text, streaming: streaming))
    }

    static func started(_ seq: Int = 0, prompt: String = "Do the thing", task: String = "t1") -> ConversationTimelineRow {
        let started = TaskEvent.TaskStarted(
            backend: "claude", freedom: "write_in_repo", repoPath: "/repo", prompt: prompt, model: nil,
            reasoningEffort: nil, spawnedBy: nil, group: nil, liveInput: nil
        )
        return row(seq, task: task, .started(started))
    }

    static func message(_ seq: Int, _ text: String, source: String, task: String = "t1") -> ConversationTimelineRow {
        row(seq, task: task, .message(text: text, source: source))
    }

    static func separator(_ text: String, task: String) -> ConversationTimelineRow {
        ConversationTimelineRow(id: "sep:\(task)", taskID: task, timestamp: base, kind: .separator(text: text), live: false)
    }
}

extension ActivityRow {
    var group: ToolGroup? {
        if case .toolGroup(let group) = self { return group }
        return nil
    }

    var singleRowID: String? {
        if case .single(let row) = self { return row.id }
        return nil
    }
}
