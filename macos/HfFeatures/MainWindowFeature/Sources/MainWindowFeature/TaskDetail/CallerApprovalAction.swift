import Foundation
import MonitorCore

// MARK: - CallerApprovalAction

/// Lossless readable leaves. Paths retain object keys and array positions; empty containers and
/// scalar types remain explicit. Only the four routine Codex correlation fields are exempt.
struct CallerApprovalAction: Equatable, Sendable {
    struct Field: Equatable, Sendable, Identifiable {
        let id: String
        let label: String
        let value: String
        let type: String
    }

    let title: String
    let fields: [Field]
    let covered: Bool
    let knownEnums: Bool

    nonisolated static func build(_ request: CallerApprovalRequest) -> Self {
        guard let action = request.raw["action"]?.objectValue,
              let input = action["input"]?.objectValue else {
            return Self(title: request.text("tool_name").isEmpty ? "Requested action" : request.text("tool_name"),
                        fields: [], covered: false, knownEnums: false)
        }
        let tool = action["tool_name"]?.stringValue ?? request.text("tool_name")
        let codex = ["commandexecution", "filechange"].contains(tool.lowercased())
        let routine: Set = ["threadId", "turnId", "itemId", "startedAtMs"]
        var fields: [Field] = [Field(id: "tool", label: "Tool", value: tool, type: "Text")]
        func escape(_ key: String) -> String { key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }
        func append(_ value: JSONValue, path: String, label: String) {
            switch value {
            case .object(let object) where !object.isEmpty:
                for key in object.keys.sorted() {
                    if let child = object[key] { append(child, path: path + "/" + escape(key), label: label + " · " + key) }
                }
            case .array(let array) where !array.isEmpty:
                for (index, child) in array.enumerated() {
                    append(child, path: "\(path)/\(index)", label: "\(label) · \(index + 1)")
                }
            default:
                let text: String
                let type: String
                switch value {
                case .string(let string): text = string; type = string.isEmpty ? "Empty text" : "Text"
                case .null: text = "No value"; type = "Null"
                case .object: text = "Empty object"; type = "Object"
                case .array: text = "Empty list"; type = "List"
                case .bool(let boolean): text = boolean ? "true" : "false"; type = "Boolean"
                case .number: text = value.rendered(); type = "Number"
                }
                fields.append(Field(id: path, label: label, value: text, type: type))
            }
        }
        let labels = ["command": "Command", "cwd": "Working directory", "file_path": "Path", "content": "Content",
                      "old_string": "Replace this text", "new_string": "With this text", "changes": "File changes"]
        for key in input.keys.sorted() where !(codex && routine.contains(key)) {
            if let value = input[key] {
                append(value, path: "input/" + escape(key), label: codex && key == "reason" ? "Agent's stated reason" : labels[key] ?? key)
            }
        }
        // Preserve future action-level authorization fields as well as unknown input keys.
        for key in action.keys.sorted() where !["input", "tool_name"].contains(key) {
            if let value = action[key] { append(value, path: "action/" + escape(key), label: key) }
        }
        if input.isEmpty { append(.object([:]), path: "input", label: "Input") }
        let title = ["bash": "Run command", "commandexecution": "Run command", "write": "Write file",
                     "edit": "Edit file", "filechange": "Change files"][tool.lowercased()] ?? tool
        return Self(title: title.isEmpty ? "Requested action" : title, fields: fields, covered: true,
                    knownEnums: knownActionEnums(tool: tool, input: input))
    }

    private nonisolated static func knownActionEnums(tool: String, input: [String: JSONValue]) -> Bool {
        guard tool.lowercased() == "filechange" else { return true }
        guard let changes = input["changes"]?.arrayValue else { return false }
        return changes.allSatisfy { change in
            guard let kind = change["kind"]?.objectValue, let type = kind["type"]?.stringValue else { return false }
            return ["add", "update", "delete"].contains(type)
        }
    }
}

// MARK: - CallerApprovalCardModel

struct CallerApprovalCardModel: Equatable, Identifiable, Sendable {
    let request: CallerApprovalRequest
    let action: CallerApprovalAction
    let pending: Bool
    let expanded: Bool
    var canRespond: Bool
    var showsDecisionControls = true
    let notice: String?
    let submitting: Bool
    var focusToken: UUID?
    var id: String { request.id }
    var source: String {
        let tool = request.text("tool_name")
        let input = request.raw["action"]?["input"]?.objectValue ?? [:]
        let summary = [input["command"]?.stringValue, input["file_path"]?.stringValue,
                       request.raw["description"]?.stringValue]
.compactMap(\.self)
.first ?? action.title
        return "Waiting for approval: \(tool) · \(String(summary.prefix(100)))"
    }
}
