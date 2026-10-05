import MonitorCore
import PbUI

// MARK: - WorkflowCandidateSettings

/// Workflow turn budgets are independent from node attempt and transition limits.
enum WorkflowCandidateSettings {
    static func make(backend: String) -> [String: JSONValue] {
        replacingBackend(in: [:], with: backend)
    }

    static func turnLimitText(_ candidate: [String: JSONValue]) -> String {
        guard BackendStyle.supportsTurnLimit(candidate["backend"]?.stringValue ?? "") else { return "" }
        return candidate["max_turns"]?.intValue.map(String.init) ?? candidate["max_turns"]?.stringValue ?? "100"
    }

    static func replacingBackend(in candidate: [String: JSONValue], with backend: String) -> [String: JSONValue] {
        guard candidate["backend"]?.stringValue != backend else { return candidate }
        var value = candidate
        value["backend"] = backend.isEmpty ? nil : .string(backend)
        value["model"] = nil
        value["reasoning_effort"] = nil
        if BackendStyle.supportsTurnLimit(backend) {
            value["max_turns"] = value["max_turns"] ?? .number(100)
        } else {
            value["max_turns"] = nil
        }
        return value
    }
}
