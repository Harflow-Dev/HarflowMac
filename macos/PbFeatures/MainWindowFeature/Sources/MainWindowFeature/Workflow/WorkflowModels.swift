import Foundation
import MonitorCore

// MARK: - WorkflowRecord

struct WorkflowRecord: Identifiable, Equatable, Sendable {
    var raw: [String: JSONValue]
    var id: String { raw["name"]?.stringValue ?? "" }
    var workflowID: String { raw["workflow_id"]?.stringValue ?? definition["workflow_id"]?.stringValue ?? "" }
    var revision: Int { raw["revision"]?.intValue ?? 0 }
    var definition: [String: JSONValue] { raw["definition"]?.objectValue ?? raw }
    var description: String { definition["description"]?.stringValue ?? "" }
}

// MARK: - WorkflowNodeModel

struct WorkflowNodeModel: Identifiable, Equatable {
    var raw: [String: JSONValue]
    var id: String { raw["id"]?.stringValue ?? "" }
    var name: String { raw["title"]?.stringValue ?? id }
    var type: String { raw["type"]?.stringValue ?? "agent" }
    var role: String { raw["role"]?.stringValue ?? "task" }
    var executionMode: String { raw["execution_mode"]?.stringValue ?? "headless" }
    var instructions: String { raw["instructions"]?.stringValue ?? "" }
    var isParallelBoundary: Bool { ["parallel_start", "parallel_end"].contains(type) }
    var parallelGroupID: String? { raw["parallel_group_id"]?.stringValue }
    var isOptional: Bool { ["agent", "workflow"].contains(type) && (raw["optional"]?.boolValue ?? false) }
    var position: CGPoint {
        let position = raw["position"]?.objectValue ?? [:]
        return CGPoint(x: position["x"]?.doubleValue ?? 80, y: position["y"]?.doubleValue ?? 80)
    }

    var workflowID: String { raw["workflow_ref"]?["workflow_id"]?.stringValue ?? "" }
    var workflowName: String { raw["workflow_name"]?.stringValue ?? "" }
    var orchestratorMode: String { raw["orchestrator_mode"]?.stringValue ?? "child" }
    var childSessionPolicy: String { raw["child_session_policy"]?.stringValue ?? "agent_decides" }
    var showsChildSessionPolicy: Bool { type == "workflow" && orchestratorMode == "child" }

    var backend: String { raw["agent"]?["backend"]?.stringValue ?? "" }
}

// MARK: - WorkflowEdgeModel

struct WorkflowEdgeModel: Identifiable, Equatable {
    var raw: [String: JSONValue]
    var id: String { raw["id"]?.stringValue ?? "" }
    var source: String { raw["source"]?.stringValue ?? "" }
    var target: String { raw["target"]?.stringValue ?? "" }
    var condition: String { raw["condition"]?.stringValue ?? "" }
    var isDefault: Bool { raw["default"]?.boolValue ?? false }
    var isBackward: Bool { raw["backward"]?.boolValue ?? false }
    var maxRetries: Int? { raw["max_retries"]?.intValue }
}

// MARK: - WorkflowRunModel

struct WorkflowRunModel: Identifiable, Equatable {
    var raw: [String: JSONValue]
    var id: String { raw["workflow_run_id"]?.stringValue ?? raw["run_id"]?.stringValue ?? "" }
    var name: String { raw["workflow_name"]?.stringValue ?? raw["name"]?.stringValue ?? "Workflow" }
    var status: String { raw["status"]?.stringValue ?? "unknown" }
    var reason: String { raw["attention_reason"]?.stringValue ?? raw["reason"]?.stringValue ?? "" }
    var isDelegation: Bool { raw["execution_contract"]?.stringValue == "delegation" }
    var orchestratorPermissions: WorkflowPermissionsModel? {
        raw["owner_contracts"]?.objectValue.flatMap(WorkflowPermissionsModel.init)
    }

    var schedulingPolicyDescription: String? {
        guard raw["scheduling_policy"]?.stringValue == "native_workers_plus_control_v1" else { return nil }
        let workers = definition["max_parallel"]?.intValue ?? 4
        return "Up to \(workers) \(workers == 1 ? "worker" : "workers") + one shared orchestrator turn"
    }

    var parentRunID: String? { raw["parent_workflow_run_id"]?.stringValue ?? raw["parent_link"]?["workflow_run_id"]?.stringValue }
    var rootRunID: String { raw["root_workflow_run_id"]?.stringValue ?? raw["parent_link"]?["root_workflow_run_id"]?.stringValue ?? id }
    var sessionOwnerRunID: String { raw["orchestrator_session_owner_run_id"]?.stringValue ?? id }
    var childRunIDs: [String] {
        activations.compactMap { $0["invocation"]?["child_workflow_run_id"]?.stringValue }
    }

    func latestChildRunID(for nodeID: String, selection: WorkflowBranchSelection = WorkflowBranchSelection()) -> String? {
        guard !selection.excludedNodeIDs.contains(nodeID) else { return nil }
        let activation = activations.last {
            $0["node_id"]?.stringValue == nodeID && selection.includes($0, nodeID: nodeID) && $0["invocation"]?["child_workflow_run_id"]?.stringValue != nil
        }
        return activation?["invocation"]?["child_workflow_run_id"]?.stringValue
    }

    func childRunLabel(_ childID: String) -> String {
        let activation = activations.last { $0["invocation"]?["child_workflow_run_id"]?.stringValue == childID }
        let invocation = activation?["invocation"]
        let name = invocation?["workflow_name"]?.stringValue ?? "Child workflow"
        let outcome = activation?["node_result"]?["result"]?["child_outcome"]
        let status = outcome?["child_status"]?.stringValue ?? invocation?["stage"]?.stringValue ?? "unknown"
        return "\(name.isEmpty ? "Child workflow" : name) · \(status.replacingOccurrences(of: "_", with: " "))"
    }

    var allowsMonitorControl: Bool {
        guard parentRunID == nil else { return false }
        guard raw["status"]?.stringValue != nil else { return false }
        return raw["interaction_owner"]?.stringValue != "caller"
    }

    var canCancelFromMonitor: Bool {
        guard parentRunID == nil, !["completed", "failed", "cancelled", "cancelling"].contains(status) else { return false }
        if let eligibility = raw["can_cancel_from_monitor"]?.boolValue { return eligibility }
        // Older ctl versions can safely control their own Monitor-owned runs.
        return allowsMonitorControl
    }

    /// The backend's durable explanation for an unavailable root cancellation action.
    /// Children and settled runs already have separate guidance in the header.
    var monitorCancelRefusalReason: String? {
        guard parentRunID == nil, !canCancelFromMonitor,
              !["completed", "failed", "cancelled", "cancelling"].contains(status),
              let reason = raw["monitor_cancel_reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else { return nil }
        return reason
    }

    var isSettling: Bool { raw["settling"]?.boolValue ?? false }
    var canSkipOptionalReview: Bool {
        isDelegation && allowsMonitorControl && status == "needs_input" && !isSettling
            && raw["optional_review_skip_available"]?.boolValue == true
            && !(raw["input_decision_id"]?.stringValue ?? "").isEmpty
    }

    var canRecover: Bool { isDelegation && status == "failed" && !isSettling }
    var requiresAnswer: Bool { isDelegation && ["needs_input", "needs_attention", "failed"].contains(status) }
    var question: String { raw["input_question"]?.stringValue ?? raw["question"]?.stringValue ?? reason }
    var isBuilder: Bool { raw["kind"]?.stringValue == "builder" }
    var isBuilderProposal: Bool { raw["editing_definition"] != nil || raw["builder_followup"]?.boolValue == true }
    var builderDraftRevision: Int { raw["draft_revision"]?.intValue ?? 0 }
    var builderTaskID: String? {
        activations.last { $0["role"]?.stringValue == "builder" }?["tasks"]?.arrayValue?.last?["task_id"]?.stringValue
    }

    var definition: [String: JSONValue] {
        if isBuilder { return raw["builder_draft"]?.objectValue ?? raw["editing_definition"]?.objectValue ?? [:] }
        return raw["definition"]?.objectValue ?? [:]
    }

    var emptyChecklistPresentation: WorkflowEmptyChecklistPresentation {
        let planningIDs = Set(WorkflowJSON.nodes(definition).filter { $0.role == "planning" }.map(\.id))
        let proposal = activations.reversed().first {
            planningIDs.contains($0["node_id"]?.stringValue ?? "")
                && $0["status"]?.stringValue == "completed"
                && $0["node_result"]?["status"]?.stringValue == "succeeded"
        }
        let disposition = raw["checklist_disposition"]?.objectValue
        let isAccepted = disposition?["status"]?.stringValue == "not_needed"
            && (proposal == nil || disposition?["execution_id"]?.stringValue == proposal?["id"]?.stringValue)
        if isAccepted {
            return .init(title: "No checklist needed", reason: disposition?["reason"]?.stringValue)
        }
        if proposal?["node_result"]?["result"]?["no_checklist_needed"]?.boolValue == true {
            return .init(title: "No checklist proposed", reason: proposal?["node_result"]?["result"]?["checklist_reason"]?.stringValue)
        }
        return .init(title: ["starting", "running", "needs_input", "paused"].contains(status)
            ? "Waiting for a plan…" : "No plan was provided for this run.", reason: nil)
    }

    var technicalPlan: String? {
        if let plan = raw["technical_plan"]?.stringValue, !plan.isEmpty { return plan }
        let planningIDs = Set(WorkflowJSON.nodes(definition).filter { $0.role == "planning" }.map(\.id))
        return activations.reversed()
.first { activation in
            activation["role"]?.stringValue == "node"
            && planningIDs.contains(activation["node_id"]?.stringValue ?? "")
            && activation["status"]?.stringValue == "completed"
            && activation["node_result"]?["status"]?.stringValue == "succeeded"
            && !(activation["node_result"]?["result"]?["technical_plan"]?.stringValue ?? "").isEmpty
        }?["node_result"]?["result"]?["technical_plan"]?.stringValue
    }

    var activations: [[String: JSONValue]] { raw["activations"]?.arrayValue?.compactMap(\.objectValue) ?? [] }
    var tasks: [[String: JSONValue]] { raw["tasks"]?.arrayValue?.compactMap(\.objectValue) ?? [] }
}

// MARK: - WorkflowJSON

enum WorkflowJSON {
    static func objects(_ value: JSONValue?) -> [[String: JSONValue]] {
        value?.arrayValue?.compactMap(\.objectValue) ?? []
    }

    static func nodes(_ definition: [String: JSONValue]) -> [WorkflowNodeModel] {
        objects(definition["nodes"]).map { WorkflowNodeModel(raw: $0) }
    }

    static func edges(_ definition: [String: JSONValue]) -> [WorkflowEdgeModel] {
        objects(definition["connections"]).map { WorkflowEdgeModel(raw: $0) }
    }
}

// MARK: - WorkflowExecutionAttempts

enum WorkflowExecutionAttempts {
    static func fallbackIndices(_ activation: [String: JSONValue]) -> [String: Int] {
        let replies = Set(WorkflowJSON.objects(activation["questions"]).compactMap { $0["reply_task_id"]?.stringValue })
        var fallback = -1
        var indices: [String: Int] = [:]
        for task in WorkflowJSON.objects(activation["tasks"]) {
            guard let id = task["task_id"]?.stringValue else { continue }
            if !replies.contains(id) { fallback += 1 }
            indices[id] = max(0, fallback)
        }
        return indices
    }
}

// MARK: - WorkflowEmptyChecklistPresentation

struct WorkflowEmptyChecklistPresentation: Equatable {
    let title: String
    let reason: String?
}
