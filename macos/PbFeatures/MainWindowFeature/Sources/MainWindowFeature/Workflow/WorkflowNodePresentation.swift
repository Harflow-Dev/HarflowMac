import Foundation
import MonitorCore

// MARK: - WorkflowNodePresentation

/// Display projection only; durable task events keep their original contracts.
enum WorkflowNodePresentation {
    static func merged(_ snapshot: TaskInfo?, with listed: TaskInfo) -> TaskInfo {
        guard let snapshot else { return listed }
        var raw = snapshot.raw
        for (key, value) in listed.raw where key.hasPrefix("workflow_")
            || ["execution_contract", "display_prompt", "root_workflow_run_id", "suspended_via_root"].contains(key) {
            raw[key] = value
        }
        return TaskInfo(.object(raw)) ?? listed
    }

    static func isNativeControl(_ task: TaskInfo?) -> Bool {
        task?.raw["workflow_role"]?.stringValue == "native_control"
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
        if isNativeControl(task) || task.raw["execution_kind"]?.stringValue == "native_subagent" { return false }
        if task.raw["workflow_run_id"]?.stringValue == nil { return true }
        return ["completed", "failed", "cancelled"].contains(task.raw["workflow_tree_status"]?.stringValue ?? task.raw["workflow_status"]?.stringValue ?? "")
            && (task.raw["workflow_tree_settling"]?.boolValue ?? task.raw["workflow_settling"]?.boolValue) == false
            && task.raw["suspended_via_root"]?.boolValue != true
    }

    static func resultError(_ task: TaskInfo?) -> String? {
        guard let reason = task?.raw["workflow_result_error"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else { return nil }
        return String(reason.prefix(2000)) + (reason.count > 2000 ? "…" : "")
    }

    static func summary(_ text: String?, task: TaskInfo? = nil) -> String? {
        if let reason = resultError(task) { return "Malformed output\n\n" + reason }
        guard let text else { return nil }
        guard let object = contractObject(text) else { return text }
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

    /// Match accepted envelope formatting without exposing protocol text in the activity feed.
    private static func contractObject(_ text: String) -> [String: JSONValue]? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let object = JSONValue.parse(Data(source.utf8))?.objectValue { return object }
        var candidates: [[String: JSONValue]] = []
        var scanner = EnvelopeScanner()
        var start: String.Index?
        for index in source.indices {
            let character = source[index]
            if start == nil {
                guard character == "{" else { continue }
                start = index
                scanner = EnvelopeScanner()
                continue
            }
            if scanner.consume(character), let begin = start {
                let envelope = String(source[begin ... index])
                guard let object = JSONValue.parse(Data(envelope.utf8))?.objectValue else { return nil }
                candidates.append(object)
                start = nil
            }
        }
        guard let first = candidates.first, candidates.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    private struct EnvelopeScanner {
        var depth = 1
        var quoted = false
        var escaped = false

        mutating func consume(_ character: Character) -> Bool {
            if quoted {
                consumeQuoted(character)
                return false
            }
            switch character {
            case "\"": quoted = true
            case "{": depth += 1
            case "}": depth -= 1
            default: break
            }
            return depth == 0
        }

        private mutating func consumeQuoted(_ character: Character) {
            if escaped { escaped = false } else if character == "\\" {
                escaped = true
            } else if character == "\"" { quoted = false }
        }
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
        let (malformedRows, suppressed, appendAfter, standalone) = malformedProjection(rows, tasks: tasks ?? [:])
        let projected: [ConversationTimelineRow] = rows.compactMap { row in
            if suppressed.contains(row.id) { return nil }
            if let reason = malformedRows[row.id] { return malformedRow(row, reason: reason) }
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
        return projected.flatMap { row in
            if let appended = appendAfter[row.id] { return [row, appended] }
            return [row]
        } + standalone
    }

    private static func malformedProjection(_ rows: [ConversationTimelineRow], tasks: [String: TaskInfo])
        -> ([String: String], Set<String>, [String: ConversationTimelineRow], [ConversationTimelineRow]) {
        var malformedRows: [String: String] = [:]
        var suppressed: Set<String> = []
        var appendAfter: [String: ConversationTimelineRow] = [:]
        var standalone: [ConversationTimelineRow] = []
        let rowsByTask = Dictionary(grouping: rows, by: \.taskID)
        for (taskID, task) in tasks {
            guard let reason = resultError(task) else { continue }
            let ownRows = rowsByTask[taskID] ?? []
            let finalBlock = terminalTextBlock(ownRows)
            if let last = finalBlock.first {
                malformedRows[last.id] = reason
                suppressed.formUnion(finalBlock.dropFirst().map(\.id))
            } else if let last = ownRows.last {
                appendAfter[last.id] = malformedRow(last, reason: reason)
            } else {
                let anchor = ConversationTimelineRow(id: taskID, taskID: taskID, timestamp: task.startedAt, kind: .separator(text: ""), live: false)
                standalone.append(malformedRow(anchor, reason: reason))
            }
        }
        return (malformedRows, suppressed, appendAfter, standalone)
    }

    private static func terminalTextBlock(_ rows: [ConversationTimelineRow]) -> [ConversationTimelineRow] {
        var block: [ConversationTimelineRow] = []
        for row in rows.reversed() {
            guard case .item(let item) = row.kind else { break }
            if block.isEmpty {
                switch item.body {
                case .finished, .notice: continue
                default: break
                }
            }
            guard case .text = item.body else { break }
            block.append(row)
        }
        return block
    }

    /// Presentation-only tool-shaped cell; original response and events remain stored unchanged.
    private static func malformedRow(_ row: ConversationTimelineRow, reason: String) -> ConversationTimelineRow {
        let seq: Int = if case .item(let item) = row.kind { item.id } else { 0 }
        let callID = "workflow-output-error-" + row.taskID
        var call: [String: JSONValue] = ["v": .number(1), "seq": .number(Double(seq)), "kind": .string("tool_call"),
            "call_id": .string(callID), "tool": .string("Malformed output"), "category": .string("workflow_protocol_error")]
        if let time = row.timestamp { call["observed_at"] = .string(time.ISO8601Format()) }
        let result: [String: JSONValue] = ["v": .number(1), "seq": .number(Double(seq + 1)), "kind": .string("tool_result"),
            "call_id": .string(callID), "ok": .bool(false), "output_tail": .string(reason)]
        let events = [call, result].compactMap { TaskEvent(line: JSONValue.object($0).rendered()) }
        guard let item = Timeline.items(from: events).first else { return row }
        return ConversationTimelineRow(id: row.taskID + "#workflow-output-error", taskID: row.taskID, timestamp: row.timestamp, kind: .item(item), live: false)
    }

}
