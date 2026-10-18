import MonitorCore

// MARK: - WorkflowChildSessionDetails

/// Persisted child invocation choices; runtime refusal never implies a fresh launch.
struct WorkflowChildSessionDetails {
    let invocation: [String: JSONValue]

    var lines: [String] {
        var result: [String] = []
        if let selection = invocation["child_session_selection"]?.objectValue {
            if let requested = selection["requested_policy"]?.stringValue {
                result.append("Child conversation requested: " + label(requested))
            }
            if let selected = selection["selected_mode"]?.stringValue {
                result.append("Child conversation selected: " + label(selected))
            }
            for (key, title) in [("reason", "Reason"), ("source_execution_id", "Source invocation"),
                                 ("source_child_workflow_run_id", "Source workflow"), ("source_task_id", "Source task"),
                                 ("source_session_id", "Source conversation")] {
                if let value = selection[key]?.stringValue, !value.isEmpty {
                    result.append(title + ": " + value)
                }
            }
        }
        if let refusal = invocation["child_session_refusal"]?.stringValue, !refusal.isEmpty {
            result.append("Child conversation refused: " + refusal)
        }
        return result
    }

    private func label(_ value: String) -> String {
        switch value {
        case "fresh": "Fresh"
        case "resume": "Resume"
        case "agent_decides": "Agent decides"
        case "current": "Current orchestrator"
        default: value
        }
    }
}
