import Foundation
import MonitorCore

// MARK: - WorkflowNodePresentation

/// Display projection only; durable task events keep their original contracts.
enum WorkflowNodePresentation {
    static func merged(_ snapshot: TaskInfo?, with listed: TaskInfo) -> TaskInfo {
        guard let snapshot else { return listed }
        var raw = snapshot.raw
        for (key, value) in listed.raw where key.hasPrefix("workflow_") || ["execution_contract", "display_prompt"].contains(key) {
            raw[key] = value
        }
        return TaskInfo(.object(raw)) ?? listed
    }

    static func isWorker(_ task: TaskInfo) -> Bool {
        task.raw["workflow_role"]?.stringValue == "node" && task.raw["execution_contract"]?.stringValue == "delegation"
    }

    static func isManaged(_ task: TaskInfo) -> Bool {
        ["node", "orchestrator"].contains(task.raw["workflow_role"]?.stringValue ?? "")
            && task.raw["execution_contract"]?.stringValue == "delegation"
    }

    static func blocksDirectMessages(_ task: TaskInfo) -> Bool {
        task.raw["workflow_run_id"]?.stringValue != nil && task.raw["workflow_builder"]?.boolValue != true && !allowsTerminal(task)
    }

    static func allowsTerminal(_ task: TaskInfo?) -> Bool {
        guard let task else { return true }
        if task.raw["workflow_run_id"]?.stringValue == nil { return true }
        return ["completed", "failed", "cancelled"].contains(task.raw["workflow_status"]?.stringValue ?? "")
            && task.raw["workflow_settling"]?.boolValue == false
    }

    static func summary(_ text: String?) -> String? {
        guard let text else { return nil }
        var source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.hasPrefix("```json"), source.hasSuffix("```") {
            source = String(source.dropFirst(7).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let object = JSONValue.parse(Data(source.utf8))?.objectValue else { return text }
        if let decision = decisionSummary(object) { return decision }
        guard
              let status = object["status"]?.stringValue, ["succeeded", "failed", "blocked", "asking"].contains(status),
              let result = object["result"]?.objectValue, object["evidence"]?.arrayValue != nil else { return text }
        var lines = [status == "asking" ? "Asking for context" : status.capitalized]
        for key in result.keys.sorted() {
            guard let value = result[key] else { continue }
            lines.append("\(key.replacingOccurrences(of: "_", with: " ").capitalized): \(readable(value))")
        }
        if let evidence = object["evidence"]?.arrayValue, !evidence.isEmpty {
            lines.append("Evidence:\n" + evidence.map { "• " + readable($0) }.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n\n")
    }

    private static func decisionSummary(_ object: [String: JSONValue]) -> String? {
        guard let action = object["action"]?.stringValue,
           ["continue", "complete", "failed", "needs_input", "answer", "inspect"].contains(action) else { return nil }
            var lines = [action == "continue" ? "Continuing workflow" : action.replacingOccurrences(of: "_", with: " ").capitalized]
            if let reason = object["reason"]?.stringValue { lines.append(reason) }
            if let question = object["question"]?.stringValue { lines.append("Question: " + question) }
            if let answer = object["answer"]?.stringValue { lines.append("Answer: " + answer) }
            for next in object["next"]?.arrayValue ?? [] {
                if let assignment = next.objectValue?["prompt"]?.stringValue { lines.append("Assignment:\n" + assignment) }
            }
            return lines.joined(separator: "\n\n")
    }

    private static func readable(_ value: JSONValue) -> String {
        if let text = value.stringValue { return text }
        if let array = value.arrayValue { return array.map(readable).joined(separator: "\n") }
        if let object = value.objectValue {
            return object.keys.sorted().map { "\($0.replacingOccurrences(of: "_", with: " ")): \(readable(object[$0]!))" }.joined(separator: "\n")
        }
        return value.rendered()
    }

    static func visibleRows(_ rows: [ConversationTimelineRow], tasks: [String: TaskInfo]? = nil, compact: Bool = false) -> [ConversationTimelineRow] {
        rows.map { row in
            if let tasks, !(tasks[row.taskID].map(isManaged) ?? false) { return row }
            guard case let .item(item) = row.kind, case let .text(text, _) = item.body,
                  let display = summary(text), display != text else { return row }
            let projectedText = compact ? String(display.prefix(240)) + (display.count > 240 ? "… Open task for details." : "") : display
            var payload: [String: JSONValue] = ["v": .number(1), "seq": .number(Double(item.id)),
                                                "kind": .string("assistant_text"), "text": .string(projectedText)]
            if let time = item.at { payload["observed_at"] = .string(time.ISO8601Format()) }
            guard let event = TaskEvent(line: JSONValue.object(payload).rendered()),
                  let projected = Timeline.items(from: [event]).first else { return row }
            return ConversationTimelineRow(id: row.id, taskID: row.taskID, timestamp: row.timestamp, kind: .item(projected), live: row.live)
        }
    }
}
