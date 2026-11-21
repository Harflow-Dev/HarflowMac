import MonitorCore

// MARK: - WorkflowSteeringRunContext

/// Only public fields consumed by steering presentation and local admission affect a read lease.
struct WorkflowSteeringRunContext: Equatable {
    let values: [String: JSONValue]

    init(_ run: WorkflowRunModel) {
        let fields: Set = [
            "workflow_run_id", "root_workflow_run_id", "parent_workflow_run_id", "parent_link", "kind", "status",
            "settling", "tree_settling", "steering_summary", "pending_steering_count", "pending_inputs",
            "input_decision_id", "input_question", "question", "orchestrator_usage_recovery", "usage_limit_recovery",
            "monitor_controls", "attention_reason", "reason", "attention_checkpoint_id", "interaction_state"
        ]
        self.values = run.raw.filter { fields.contains($0.key) }
    }

    static func matches(_ left: WorkflowRunModel?, _ right: WorkflowRunModel?) -> Bool {
        left.map(Self.init) == right.map(Self.init)
    }
}
