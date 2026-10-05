import Foundation
import MonitorCore

// MARK: - WorkflowBuilderPresentation

enum WorkflowBuilderPresentation {
    static let proposalSummary = "Workflow changes are shown on the canvas. Review the proposal, then apply and save when ready."

    static let historicalRequest = "Workflow request from an earlier run."

    static func conversationMember(task: TaskInfo, items: [TimelineItem], prompt: String?, isBuilder: Bool) -> ConversationItemMember {
        guard isBuilder, task.raw["workflow_builder"]?.boolValue != true else {
            return ConversationItemMember(task: task, items: items, prompt: prompt)
        }
        let initialPrompt = items.compactMap { item -> String? in
            if case let .started(started) = item.body { return started.prompt }
            return nil
        }
.first ?? prompt
        let projected = items.map { item -> TimelineItem in
            var payload: [String: JSONValue] = ["v": .number(1), "seq": .number(Double(item.id))]
            switch item.body {
            case let .started(started):
                payload["kind"] = .string("task_started")
                payload["prompt"] = .string(historicalRequest)
                let fields = ["backend": started.backend, "freedom": started.freedom, "repo_path": started.repoPath,
                              "model": started.model, "reasoning_effort": started.reasoningEffort,
                              "spawned_by": started.spawnedBy, "group": started.group]
                for (key, value) in fields { if let value { payload[key] = .string(value) } }
                if let liveInput = started.liveInput { payload["live_input"] = .bool(liveInput) }
            case let .message(text, source) where source == "initial" && text == initialPrompt:
                payload["kind"] = .string("user_message")
                payload["text"] = .string(historicalRequest)
                payload["source"] = .string("initial")
            default: return item
            }
            if let time = item.at { payload["observed_at"] = .string(time.ISO8601Format()) }
            guard let event = TaskEvent(line: JSONValue.object(payload).rendered()) else { return item }
            return Timeline.items(from: [event]).first ?? item
        }
        return ConversationItemMember(task: task, items: projected, prompt: historicalRequest)
    }

    static func isDefinition(_ text: String) -> Bool {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```json"), value.hasSuffix("```") {
            value = String(value.dropFirst(7).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if value.hasPrefix("```\n"), value.hasSuffix("```") {
            value = String(value.dropFirst(3).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let object = JSONValue.parse(Data(value.utf8))?.objectValue,
              let nodes = object["nodes"]?.arrayValue, !nodes.isEmpty,
              let connections = object["connections"]?.arrayValue else { return false }
        return nodes.allSatisfy { node in
            node["id"]?.stringValue != nil
                && ["start", "agent", "workflow", "join", "parallel_start", "parallel_end", "end"].contains(node["type"]?.stringValue ?? "agent")
        } && connections.allSatisfy { edge in edge["source"]?.stringValue != nil && edge["target"]?.stringValue != nil }
    }

    static func visibleRows(_ rows: [ConversationTimelineRow]) -> [ConversationTimelineRow] {
        rows.map { row in
            guard case let .item(item) = row.kind, case let .text(text, _) = item.body, let message = projectedText(text) else { return row }
            // Display-only projection through the shared timeline parser; original events remain unchanged.
            var payload: [String: JSONValue] = ["v": .number(1), "seq": .number(Double(item.id)),
                                                "kind": .string("assistant_text"), "text": .string(message)]
            if let time = item.at { payload["observed_at"] = .string(time.ISO8601Format()) }
            guard let event = TaskEvent(line: JSONValue.object(payload).rendered()),
                  let projected = Timeline.items(from: [event]).first else { return row }
            return ConversationTimelineRow(id: row.id, taskID: row.taskID, timestamp: row.timestamp, kind: .item(projected), live: row.live)
        }
    }

    static func projectedText(_ text: String) -> String? {
        if isDefinition(text) { return proposalSummary }
        guard let expression = try? NSRegularExpression(pattern: "(?s)```(?:json)?[ \t]*\n(.*?)```") else { return nil }
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var result = text
        var changed = false
        for match in matches.reversed() {
            guard let contentRange = Range(match.range(at: 1), in: text), isDefinition(String(text[contentRange])),
                  let wholeRange = Range(match.range, in: result) else { continue }
            result.removeSubrange(wholeRange)
            changed = true
        }
        guard changed else { return nil }
        let explanation = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return explanation.isEmpty ? proposalSummary : explanation
    }

    static func summary(_ text: String?) -> String? {
        text.map { projectedText($0) ?? $0 }
    }
}
