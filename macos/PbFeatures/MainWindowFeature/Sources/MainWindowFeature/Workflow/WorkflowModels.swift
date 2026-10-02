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
