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
        if candidate["caller_approvals"]?.boolValue == true, candidate["max_turns"] == nil || candidate["max_turns"] == .null { return "" }
        return candidate["max_turns"]?.intValue.map(String.init) ?? candidate["max_turns"]?.stringValue ?? "100"
    }

    static func replacingBackend(in candidate: [String: JSONValue], with backend: String, supportsCallerApprovals: Bool = false) -> [String: JSONValue] {
        guard candidate["backend"]?.stringValue != backend else { return candidate }
        var value = candidate
        value["backend"] = backend.isEmpty ? nil : .string(backend)
        value["model"] = nil
        value["reasoning_effort"] = nil
        if !supportsCallerApprovals, value["caller_approvals"]?.boolValue == true { value["caller_approvals"] = .bool(false) }
        if !BackendStyle.supportsTurnLimit(backend) {
            value["max_turns"] = nil
        }
        return value
    }
}
