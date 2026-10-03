import Foundation
import MonitorCore

// MARK: - WorkflowNodePresentation

/// Display projection only; durable task events keep their original contracts.
enum WorkflowNodePresentation {
    static func isWorker(_ task: TaskInfo) -> Bool {
        task.raw["workflow_role"]?.stringValue == "node" && task.raw["execution_contract"]?.stringValue == "delegation"
    }

    static func allowsTerminal(_ task: TaskInfo?) -> Bool {
        guard let task else { return true }
        return task.raw["workflow_run_id"]?.stringValue == nil || task.raw["workflow_status"]?.stringValue == "completed"
    }

    static func summary(_ text: String?) -> String? {
        guard let text else { return nil }
        var source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.hasPrefix("```json"), source.hasSuffix("```") {
            source = String(source.dropFirst(7).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let object = JSONValue.parse(Data(source.utf8))?.objectValue,
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

    private static func readable(_ value: JSONValue) -> String {
        if let text = value.stringValue { return text }
        if let array = value.arrayValue { return array.map(readable).joined(separator: "\n") }
        if let object = value.objectValue {
            return object.keys.sorted().map { "\($0.replacingOccurrences(of: "_", with: " ")): \(readable(object[$0]!))" }.joined(separator: "\n")
        }
        return value.rendered()
    }

    static func visibleRows(_ rows: [ConversationTimelineRow]) -> [ConversationTimelineRow] {
        rows.map { row in
            guard case let .item(item) = row.kind, case let .text(text, _) = item.body,
                  let display = summary(text), display != text else { return row }
            var payload: [String: JSONValue] = ["v": .number(1), "seq": .number(Double(item.id)),
                                                "kind": .string("assistant_text"), "text": .string(display)]
            if let time = item.at { payload["observed_at"] = .string(time.ISO8601Format()) }
            guard let event = TaskEvent(line: JSONValue.object(payload).rendered()),
                  let projected = Timeline.items(from: [event]).first else { return row }
            return ConversationTimelineRow(id: row.id, taskID: row.taskID, timestamp: row.timestamp, kind: .item(projected), live: row.live)
        }
    }
}
