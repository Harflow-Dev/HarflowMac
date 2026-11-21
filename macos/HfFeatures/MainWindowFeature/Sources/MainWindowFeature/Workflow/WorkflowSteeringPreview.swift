#if DEBUG
import Foundation
import MonitorCore

// MARK: - WorkflowSteeringPreview

/// Synthetic feature-local wire values, never repository authority or runtime initialization.
@MainActor
enum WorkflowSteeringPreview {
    static func make(state: String = "awaiting_caller") -> WorkflowVM {
        let vm = WorkflowPreview.make(run: true)
        let root = String(repeating: "a", count: 32)
        let episode = String(repeating: "b", count: 32)
        let turn = String(repeating: "c", count: 32)
        let target = target(root: root)
        var raw = vm.selectedRun?.raw ?? [:]
        raw["workflow_run_id"] = .string(root)
        raw["root_workflow_run_id"] = .string(root)
        raw["status"] = .string("paused")
        raw["steering_summary"] = .object(["hold": .bool(state != "dismissed")])
        raw["attention_reason"] = .string(WorkflowSteeringPresentation.parkedReason)
        vm.selectedRun = WorkflowRunModel(raw: raw)
        vm.selectedNodeID = WorkflowStandalone.orchestratorID
        let result: [String: Any] = [
            "root_workflow_run_id": root, "steering_version": 1, "request_schema_version": 2,
            "interaction_epoch": 1, "control_revision": 1, "ledger_epoch": 1, "sequence": 3,
            "owner": "monitor", "eligible_actions": ["reply", "dismiss", "retarget", "open"],
            "targets": [target], "episodes": [["episode_id": episode, "steering_revision": 1,
                                                "state": state, "hold": state != "dismissed", "target": target]]
        ]
        let items: [[String: Any]] = [
            ["sequence": 1, "kind": "requested", "episode_id": episode, "turn_id": turn, "action": "open", "text": "Explain the current plan."],
            ["sequence": 2, "kind": "final_captured", "episode_id": episode, "turn_id": turn, "text": "Which part would you like to discuss?"],
            ["sequence": 3, "kind": "classified", "episode_id": episode, "turn_id": turn, "outcome": "conversation"]
        ]
        let history: [String: Any] = ["root_workflow_run_id": root, "items": items, "has_more": false,
                                      "next_cursor": NSNull(), "gap": false, "history_incomplete": false]
        if let data = envelope(result), let status = WorkflowSteeringStatus(data: data, rootID: root),
           let historyData = envelope(history), let page = WorkflowSteeringHistoryPage(data: historyData, rootID: root), let run = vm.selectedRun {
            vm.steering = WorkflowSteeringPresentation.make(status: status, run: run, history: page.items, observedAt: .now)
        }
        return vm
    }

    private static func envelope(_ result: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["product": "harflow", "format": "harflow.ctl", "v": 1,
                                                     "product_version": "0.0.14", "result": result])
    }

    private static func target(root: String) -> [String: Any] {
        var value: [String: Any] = ["root_workflow_run_id": root, "workflow_run_id": root, "path": [root], "role": "orchestrator",
                                    "checkpoint_revision": 1, "goal_revision": 1, "interaction_epoch": 1, "control_revision": 1]
        let nullable = ["assignment_revision", "draft_revision", "source_revision", "activation_id", "assignment_digest", "decision_id",
                        "definition_digest", "node_id", "preview_hash", "source_definition_digest", "source_workflow_id", "task_id", "token_id"]
        for key in nullable { value[key] = NSNull() }
        return value
    }
}
#endif
