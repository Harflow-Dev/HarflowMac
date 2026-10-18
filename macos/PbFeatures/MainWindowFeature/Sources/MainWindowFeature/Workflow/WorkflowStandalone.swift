import MonitorCore
import SwiftUI

// MARK: - WorkflowStandalone

enum WorkflowStandalone {
    static let orchestratorID = "__orchestrator__"
}

extension WorkflowViewModel {
    var standaloneNodes: [WorkflowNodeModel] {
        if let run = selectedRun {
            if run.isBuilder {
                return WorkflowJSON.objects(run.definition["on_demand_nodes"]).map { WorkflowNodeModel(raw: $0) }
            }
            return run.onDemandNodes
        }
        return WorkflowJSON.objects(definition["on_demand_nodes"]).map { WorkflowNodeModel(raw: $0) }
    }

    var selectedOnDemandNode: WorkflowNodeModel? { standaloneNodes.first { $0.id == selectedNodeID } }
    var isOrchestratorSelected: Bool { selectedNodeID == WorkflowStandalone.orchestratorID }

    func selectStandalone(_ id: String) {
        connectionSourceID = nil
        selectedEdgeID = nil
        selectedNodeID = id
    }

    func addOnDemandNode() {
        guard selectedRun == nil, !isBusy else { return }
        let id = "specialist_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let node: [String: JSONValue] = [
            "id": .string(id), "title": .string(""), "instructions": .string(""), "call_condition": .string(""),
            "agent": .object(["backend": .string(backendIDs.first ?? "codex")]),
            "freedom": .string("read_only"), "session_mode": .string("agent_decides"), "execution_mode": .string("headless")
        ]
        definition["on_demand_nodes"] = .array((definition["on_demand_nodes"]?.arrayValue ?? []) + [.object(node)])
        selectStandalone(id)
    }
}

// MARK: - WorkflowOnDemandCall

struct WorkflowOnDemandCall: Identifiable, Equatable {
    var raw: [String: JSONValue]
    var id: String { raw["id"]?.stringValue ?? "" }
    var nodeID: String { raw["node_id"]?.stringValue ?? "" }
    var number: Int { raw["call_number"]?.intValue ?? 0 }
    var assignment: String { raw["assignment"]?.stringValue ?? "" }
    var reason: String { raw["reason"]?.stringValue ?? "" }
    var status: String { raw["status"]?.stringValue ?? "unknown" }
    var taskID: String? { raw["task_id"]?.stringValue }
    var origin: String {
        let title = raw["origin"]?["title"]?.stringValue ?? "step"
        switch raw["origin"]?["kind"]?.stringValue {
        case "node_question": return "Called by the orchestrator while answering \(title)'s question"
        case "child_question": return "Called by the orchestrator for the child workflow's question (\(title))"
        default: return "Called by the orchestrator after \(title)"
        }
    }

    var result: String {
        var pieces: [String] = []
        if let failure = raw["failure"]?.stringValue, !failure.isEmpty { pieces.append(failure) }
        if let result = raw["result"], result != .null { pieces.append(result.rendered()) }
        return pieces.joined(separator: "\n\n")
    }
}

extension WorkflowRunModel {
    var onDemandNodes: [WorkflowNodeModel] {
        WorkflowJSON.objects(raw["on_demand_nodes"]).map { entry in
            var node = entry
            node["id"] = entry["node_id"]
            return WorkflowNodeModel(raw: node)
        }
    }

    var onDemandCalls: [WorkflowOnDemandCall] {
        WorkflowJSON.objects(raw["on_demand_calls"]).map { WorkflowOnDemandCall(raw: $0) }
    }

    var onDemandState: [String: JSONValue] { raw["on_demand_state"]?.objectValue ?? [:] }
}

// MARK: - Saved editor normalization

extension WorkflowStandalone {
    static func normalized(_ definition: [String: JSONValue]) -> [String: JSONValue] {
        let originalNodes = definition["nodes"]?.arrayValue
        var nodes = WorkflowJSON.objects(definition["nodes"])
        guard nodes.contains(where: { $0["type"]?.stringValue == "start" && $0["prompt"] != nil }) else { return definition }
        var result = definition
        var orchestrator = result["orchestrator"]?.objectValue ?? [:]
        if orchestrator["instructions"] == nil,
           let prompt = nodes.first(where: { $0["type"]?.stringValue == "start" })?["prompt"] {
            orchestrator["instructions"] = prompt
            result["orchestrator"] = .object(orchestrator)
        }
        for index in nodes.indices where nodes[index]["type"]?.stringValue == "start" {
            nodes[index].removeValue(forKey: "prompt")
        }
        if let originalNodes {
            var objects = nodes.makeIterator()
            result["nodes"] = .array(originalNodes.map { value in
                value.objectValue == nil ? value : .object(objects.next() ?? [:])
            })
        }
        return result
    }
}

// MARK: - Standalone deletion

extension WorkflowVM {
    var selectedNode: WorkflowNodeModel? { nodes.first { $0.id == selectedNodeID } }

    func deleteStandaloneSelection() -> Bool {
        if isOrchestratorSelected { return true }
        guard let node = selectedOnDemandNode else { return false }
        definition["on_demand_nodes"] = .array(WorkflowJSON.objects(definition["on_demand_nodes"])
            .filter { $0["id"]?.stringValue != node.id }
.map(JSONValue.object))
        selectStandalone(WorkflowStandalone.orchestratorID)
        return true
    }
}
