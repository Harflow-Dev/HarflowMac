import HfRepository
import HfUI
import MonitorCore

// MARK: - WorkflowCandidateSettings

/// Workflow turn budgets are independent from node attempt and transition limits.
enum WorkflowCandidateSettings {
    static func make(backend: String) -> [String: JSONValue] {
        replacingBackend(in: [:], with: backend)
    }

    /// The Turn limit field's text. The implied default of 100 is shown only where the engine says
    /// the harness takes a turn cap; otherwise only an explicitly saved value appears.
    static func turnLimitText(_ candidate: [String: JSONValue], turnCap: ControlState) -> String {
        if candidate["caller_approvals"]?.boolValue == true, candidate["max_turns"] == nil || candidate["max_turns"] == .null { return "" }
        let saved = candidate["max_turns"].flatMap { $0 == .null ? nil : $0 }
        if let saved { return saved.intValue.map(String.init) ?? saved.stringValue ?? "" }
        return turnCap == .supported ? "100" : ""
    }

    /// Replaces the harness, clearing model and effort. `max_turns` is kept only when the new
    /// harness's turn cap is known to be supported; `make(backend:)` builds an empty candidate, so
    /// nothing is lost there.
    static func replacingBackend(
        in candidate: [String: JSONValue], with backend: String,
        supportsCallerApprovals: Bool = false, supportsTurnCap: Bool = false
    ) -> [String: JSONValue] {
        guard candidate["backend"]?.stringValue != backend else { return candidate }
        var value = candidate
        value["backend"] = backend.isEmpty ? nil : .string(backend)
        value["model"] = nil
        value["reasoning_effort"] = nil
        if !supportsCallerApprovals, value["caller_approvals"]?.boolValue == true { value["caller_approvals"] = .bool(false) }
        if !supportsTurnCap {
            value["max_turns"] = nil
        }
        return value
    }
}
