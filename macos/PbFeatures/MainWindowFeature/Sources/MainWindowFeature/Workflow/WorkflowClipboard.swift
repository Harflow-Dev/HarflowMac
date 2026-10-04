import AppKit
import MonitorCore
import SwiftUI

// MARK: - WorkflowClipboard

enum WorkflowClipboard {
    static let type = NSPasteboard.PasteboardType("dev.polybridge.workflow-nodes")

    static func payload(definition: [String: JSONValue], selection: Set<String>) -> [String: JSONValue]? {
        let nodes = WorkflowJSON.objects(definition["nodes"]).filter { selection.contains($0["id"]?.stringValue ?? "") }
        guard !nodes.isEmpty else { return nil }
        let ids = Set(nodes.compactMap { $0["id"]?.stringValue })
        let edges = WorkflowJSON.edges(definition).filter { ids.contains($0.source) && ids.contains($0.target) }
        return ["nodes": .array(nodes.map(JSONValue.object)), "connections": .array(edges.map { .object($0.raw) })]
    }

    static func pasted(_ payload: [String: JSONValue], into definition: [String: JSONValue]) -> (definition: [String: JSONValue], ids: Set<String>)? {
        let existing = WorkflowJSON.nodes(definition)
        var terminalTypes = Set(existing.filter { ["start", "end"].contains($0.type) }.map(\.type))
        let originals = WorkflowJSON.nodes(payload).filter { node in
            guard ["start", "end"].contains(node.type) else { return true }
            return terminalTypes.insert(node.type).inserted
        }
        guard !originals.isEmpty, originals.allSatisfy({ !$0.id.isEmpty && $0.position.x.isFinite && $0.position.y.isFinite }) else { return nil }
        var offset: CGFloat = 40
        let minimumX = originals.map(\.position.x).min() ?? 0
        let minimumY = originals.map(\.position.y).min() ?? 0
        let correction = CGPoint(x: max(0, -minimumX), y: max(0, -minimumY))
        func point(_ node: WorkflowNodeModel) -> CGPoint {
            WorkflowCanvasGeometry.snapped(CGPoint(x: node.position.x + correction.x + offset, y: node.position.y + correction.y + offset))
        }
        while originals.contains(where: { node in
            let bounds = CGRect(origin: point(node), size: WorkflowCanvasGeometry.size(node)).insetBy(dx: -20, dy: -20)
            return existing.contains { bounds.intersects(CGRect(origin: $0.position, size: WorkflowCanvasGeometry.size($0))) }
        }) { offset += 40 }
        // Even partial copies get new group identities, so they cannot accidentally pair with originals.
        var groups: [String: String] = [:]
        for node in originals where node.isParallelBoundary {
            if let group = node.parallelGroupID, groups[group] == nil { groups[group] = UUID().uuidString.lowercased() }
        }
        var mapping: [String: String] = [:]
        let copies = originals.map { node -> JSONValue in
            var raw = node.raw
            let id = "node_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            mapping[node.id] = id
            raw["id"] = .string(id)
            if let group = node.parallelGroupID, let replacement = groups[group] { raw["parallel_group_id"] = .string(replacement) }
            let position = point(node)
            raw["position"] = .object(["x": .number(position.x), "y": .number(position.y)])
            return .object(raw)
        }
        let edges = WorkflowJSON.edges(payload).compactMap { edge -> JSONValue? in
            guard let source = mapping[edge.source], let target = mapping[edge.target] else { return nil }
            var raw = edge.raw
            raw["id"] = .string("edge_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))
            raw["source"] = .string(source)
            raw["target"] = .string(target)
            return .object(raw)
        }
        var result = definition
        result["nodes"] = .array((definition["nodes"]?.arrayValue ?? []) + copies)
        result["connections"] = .array((definition["connections"]?.arrayValue ?? []) + edges)
        return (result, Set(mapping.values))
    }
}

// MARK: - WorkflowVM clipboard

extension WorkflowVM {
    func copySelectedNodes() {
        guard selectedRun == nil, !isBusy, let payload = WorkflowClipboard.payload(definition: definition, selection: selectedNodeIDs) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(JSONValue.object(payload).rendered(), forType: WorkflowClipboard.type)
    }

    func pasteNodes() {
        guard selectedRun == nil, !isBusy,
              let text = NSPasteboard.general.string(forType: WorkflowClipboard.type), let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(JSONValue.self, from: data).objectValue,
              let result = WorkflowClipboard.pasted(payload, into: definition) else { return }
        definition = result.definition
        selectNodes(result.ids)
    }
}

// MARK: - WorkflowClipboardCommands

struct WorkflowClipboardCommands: ViewModifier {
    let isEnabled: Bool
    let onCopy: () -> Void
    let onPaste: () -> Void

    func body(content: Content) -> some View {
        content.onKeyPress(characters: CharacterSet(charactersIn: "cv")) { press in
            guard isEnabled, press.modifiers == .command else { return .ignored }
            if press.characters == "c" { onCopy() } else { onPaste() }
            return .handled
        }
    }
}
