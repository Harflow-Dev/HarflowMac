import Foundation
import MonitorCore

// MARK: - WorkflowVM selection

extension WorkflowVM {
    func selectNode(_ id: String) {
        if let source = connectionSourceID, source != id, selectedRun == nil {
            addEdge(source: source, target: id)
            connectionSourceID = nil
        }
        selectedNodeID = selectedRun != nil && selectedNodeID == id ? nil : id
        selectedEdgeID = nil
        selectedActivationID = nil
        scheduleRunSidebar()
    }

    func selectNodes(_ ids: Set<String>, primary: String? = nil) {
        let valid = ids.intersection(Set(nodes.map(\.id)))
        selectedNodeIDs = valid
        primaryNodeID = primary.flatMap { valid.contains($0) ? $0 : nil } ?? valid.sorted().first
        selectedEdgeID = nil
        connectionSourceID = nil
        selectedActivationID = nil
        scheduleRunSidebar()
    }

    func toggleNode(_ id: String) {
        var selection = selectedNodeIDs
        if !selection.insert(id).inserted { selection.remove(id) }
        selectNodes(selection, primary: selection.contains(id) ? id : primaryNodeID)
    }

    func moveNodes(_ positions: [String: CGPoint]) {
        guard selectedRun == nil, !positions.isEmpty else { return }
        var entries = WorkflowJSON.objects(definition["nodes"])
        for index in entries.indices {
            guard let id = entries[index]["id"]?.stringValue, let point = positions[id] else { continue }
            entries[index]["position"] = .object(["x": .number(max(0, point.x)), "y": .number(max(0, point.y))])
        }
        let value = JSONValue.array(entries.map(JSONValue.object))
        guard definition["nodes"] != value else { return }
        definition["nodes"] = value
    }

    func updateNode(_ id: String, key: String, value: JSONValue?) {
        guard selectedRun == nil else { return }
        let collection = WorkflowJSON.objects(definition["on_demand_nodes"]).contains { $0["id"]?.stringValue == id } ? "on_demand_nodes" : "nodes"
        var entries = WorkflowJSON.objects(definition[collection])
        guard let index = entries.firstIndex(where: { $0["id"]?.stringValue == id }) else {
            return
        }
        entries[index] = WorkflowAccess.updating(entries[index], key: key, value: value)
        definition[collection] = .array(entries.map(JSONValue.object))
    }

    func updateEdge(_ id: String, key: String, value: JSONValue?) {
        guard selectedRun == nil else { return }
        var entries = WorkflowJSON.objects(definition["connections"])
        guard let index = entries.firstIndex(where: { $0["id"]?.stringValue == id }) else {
            return
        }
        entries[index][key] = value
        definition["connections"] = .array(entries.map(JSONValue.object))
    }

    func moveNode(_ id: String, to point: CGPoint) {
        guard selectedRun == nil else { return }
        let point = WorkflowCanvasGeometry.snapped(point)
        let position: JSONValue = .object(["x": .number(max(0, point.x)), "y": .number(max(0, point.y))])
        guard definition["nodes"]?.arrayValue?.first(where: { $0["id"]?.stringValue == id })?["position"] != position else { return }
        updateNode(id, key: "position", value: position)
    }

}
