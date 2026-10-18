//
//  PreviewFixtures.swift
//  MainWindowFeature
//

#if DEBUG

import Foundation
import MonitorCore

// MARK: - PreviewFixtures

/// `TimelineItem`'s memberwise initializer is internal to `MonitorCore` (the type declares no
/// public one), so previews cannot build one directly — per PbUI's own preview convention ("build
/// the preview through its own public API"), these go through `TaskEvent`'s public `init?(line:)`
/// plus `Timeline.items(from:)`, exactly as a real `.events.jsonl` line would be parsed.
enum PreviewFixtures {
    static func textItem(_ text: String, seq: Int = 1) -> TimelineItem {
        item(["v": 1, "kind": "assistant_text", "seq": seq, "text": text])
    }

    static func finishedItem(status: String = "completed", exitCode: Int = 0, seq: Int = 2) -> TimelineItem {
        item(["v": 1, "kind": "task_finished", "seq": seq, "status": status, "exit_code": exitCode])
    }

    static func startedItem(
        prompt: String, backend: String = "claude", freedom: String = "write_in_repo", seq: Int = 0
    ) -> TimelineItem {
        item(["v": 1, "kind": "task_started", "seq": seq, "backend": backend, "freedom": freedom, "prompt": prompt])
    }

    static func messageItem(_ text: String, source: String, seq: Int) -> TimelineItem {
        item(["v": 1, "kind": "user_message", "seq": seq, "text": text, "source": source])
    }

    static func noticeItem(_ text: String, seq: Int) -> TimelineItem {
        item(["v": 1, "kind": "notice", "seq": seq, "text": text])
    }

    /// A tool call, paired with its result unless `pending`.
    static func toolItem(
        tool: String = "Bash", category: String = "shell", command: String? = "swift test", path: String? = nil,
        inputPreview: String? = nil, outputTail: String = "All tests passed.", exitCode: Int? = 0, ok: Bool = true,
        pending: Bool = false, seq: Int = 1, callID: String = "c1"
    ) -> TimelineItem {
        var call: [String: Any] = [
            "v": 1, "kind": "tool_call", "seq": seq, "call_id": callID, "tool": tool, "category": category,
            "input_preview": inputPreview ?? command ?? path ?? tool
        ]
        call["command"] = command
        call["path"] = path
        var events = [event(call)]
        if !pending {
            var result: [String: Any] = [
                "v": 1, "kind": "tool_result", "seq": seq + 1, "call_id": callID, "ok": ok, "output_tail": outputTail
            ]
            result["exit_code"] = exitCode
            events.append(event(result))
        }
        guard let merged = Timeline.items(from: events).first else {
            fatalError("Timeline.items(from:) produced no item for the preview fixture")
        }
        return merged
    }

    /// An edit with an old/new preview.
    static func editItem(path: String, old: String, new: String, seq: Int, callID: String = "e1") -> TimelineItem {
        let call: [String: Any] = [
            "v": 1, "kind": "tool_call", "seq": seq, "call_id": callID, "tool": "Edit", "category": "edit", "path": path,
            "input_preview": path, "edit": ["old": old, "new": new]
        ]
        let result: [String: Any] = ["v": 1, "kind": "tool_result", "seq": seq + 1, "call_id": callID, "ok": true, "output_tail": ""]
        return Timeline.items(from: [event(call), event(result)])[0]
    }

    /// A row wrapper for a fixture item; ids follow `ConversationTimeline`'s `<task>#<seq>` shape.
    static func row(_ item: TimelineItem, taskID: String = "t1", live: Bool = false) -> ConversationTimelineRow {
        ConversationTimelineRow(id: "\(taskID)#\(item.id)", taskID: taskID, timestamp: item.at, kind: .item(item), live: live)
    }

    /// A believable running turn: prompt, reads, a search, an edit, a finished command and a pending one.
    static func sampleRows(taskID: String = "t1", running: Bool = true) -> [ConversationTimelineRow] {
        var items: [TimelineItem] = [
            startedItem(prompt: "Fix the flaky login test. It fails about one run in five on CI and only when the keychain is cold.", seq: 0),
            textItem("I'll start by reading the test and the code it exercises.", seq: 1)
        ]
        let reads = ["LoginTests.swift", "LoginViewModel.swift", "KeychainStore.swift"]
        for (offset, name) in reads.enumerated() {
            items.append(toolItem(
                tool: "Read", category: "read", command: nil, path: "/Users/example/repo/Sources/\(name)",
                seq: 10 + offset * 2, callID: "r\(offset)"
            ))
        }
        items.append(textItem("The store is read before it is warmed. Let me look for other callers.", seq: 20))
        items.append(toolItem(
            tool: "Grep", category: "search", command: nil, inputPreview: #"{"pattern":"KeychainStore.read"}"#, seq: 21, callID: "s1"
        ))
        items.append(editItem(
            path: "/Users/example/repo/Sources/KeychainStore.swift", old: "let value = read(key)", new: "let value = warmed ? read(key) : nil", seq: 30
        ))
        items.append(toolItem(seq: 40, callID: "b1"))
        items.append(toolItem(command: "swift test --filter LoginTests", pending: running, seq: 42, callID: "b2"))
        if !running { items.append(finishedItem(seq: 50)) }
        return items.map { row($0, taskID: taskID, live: running) }
    }

    private static func event(_ object: [String: Any]) -> TaskEvent {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let line = String(data: data, encoding: .utf8), let event = TaskEvent(line: line) else {
            fatalError("Invalid preview fixture JSON")
        }
        return event
    }

    private static func item(_ object: [String: Any]) -> TimelineItem {
        guard let item = Timeline.items(from: [event(object)]).first else {
            fatalError("Invalid preview fixture JSON")
        }
        return item
    }
}

#endif
