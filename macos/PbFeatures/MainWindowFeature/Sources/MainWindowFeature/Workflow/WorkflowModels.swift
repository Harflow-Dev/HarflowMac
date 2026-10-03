import Foundation
import MonitorCore

// MARK: - WorkflowRecord

struct WorkflowRecord: Identifiable, Equatable {
    var raw: [String: JSONValue]
    var id: String { raw["name"]?.stringValue ?? "" }
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
    var instructions: String { raw["instructions"]?.stringValue ?? "" }
    var isOptional: Bool { type == "agent" && (raw["optional"]?.boolValue ?? false) }
    var position: CGPoint {
        let position = raw["position"]?.objectValue ?? [:]
        return CGPoint(x: position["x"]?.doubleValue ?? 80, y: position["y"]?.doubleValue ?? 80)
    }

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
    var allowsMonitorControl: Bool {
        guard raw["status"]?.stringValue != nil else { return false }
        return raw["interaction_owner"]?.stringValue != "caller"
    }

    var isSettling: Bool { raw["settling"]?.boolValue ?? false }
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
