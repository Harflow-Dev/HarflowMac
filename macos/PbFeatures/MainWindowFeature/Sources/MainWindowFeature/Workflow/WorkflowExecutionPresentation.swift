import MonitorCore

// MARK: - WorkflowExecutionPresentation

/// Projects execution identity without treating native children as process-backed tasks.
struct WorkflowExecutionPresentation: Equatable {
    let raw: [String: JSONValue]
    var isSubagent: Bool { raw["execution_kind"]?.stringValue == "native_subagent" }
    var label: String { isSubagent ? "Subagent" : "Headless" }
    var fallbackReason: String? { raw["execution_fallback_reason"]?.stringValue }
    var ownerTaskID: String? { raw["owner_task_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
    var activityLimited: Bool { isSubagent && raw["activity_level"]?.stringValue != "full" }
    var canTakeover: Bool { false }
    var canCancel: Bool { isSubagent && raw["can_cancel_child"]?.boolValue == true }
    var canResume: Bool { isSubagent && raw["can_resume_child"]?.boolValue == true }
}
