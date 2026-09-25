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
        item(#"{"v":1,"kind":"assistant_text","seq":\#(seq),"text":"\#(text)"}"#)
    }
    
    static func finishedItem(status: String = "completed", exitCode: Int = 0, seq: Int = 2) -> TimelineItem {
        item(#"{"v":1,"kind":"task_finished","seq":\#(seq),"status":"\#(status)","exit_code":\#(exitCode)}"#)
    }
    
    static func toolItem(
        tool: String = "Bash", category: String = "shell", command: String = "swift test",
        outputTail: String = "All tests passed.", exitCode: Int = 0, seq: Int = 1
    ) -> TimelineItem {
        let callLine = #"{"v":1,"kind":"tool_call","seq":\#(seq),"call_id":"c1","tool":"\#(tool)","category":"\#(category)","#
        + #""input_preview":"\#(command)","command":"\#(command)"}"#
        let resultLine = #"{"v":1,"kind":"tool_result","seq":\#(seq + 1),"call_id":"c1","ok":true,"output_tail":"\#(outputTail)","exit_code":\#(exitCode)}"#
        guard let call = TaskEvent(line: callLine), let result = TaskEvent(line: resultLine) else {
            fatalError("Invalid preview fixture JSON")
        }
        guard let merged = Timeline.items(from: [call, result]).first else {
            fatalError("Timeline.items(from:) produced no item for the preview fixture")
        }
        return merged
    }
    
    private static func item(_ line: String) -> TimelineItem {
        guard let event = TaskEvent(line: line), let item = Timeline.items(from: [event]).first else {
            fatalError("Invalid preview fixture JSON")
        }
        return item
    }
}

#endif
