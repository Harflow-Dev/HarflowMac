import Foundation
import MonitorCore
import PbCommon

// MARK: - WorkflowParallelGroup

/// Presentation helpers do not replace authoritative graph validation in Polybridge.
enum WorkflowParallelGroup {
    static func partner(of node: WorkflowNodeModel, nodes: [WorkflowNodeModel]) -> WorkflowNodeModel? {
        guard node.isParallelBoundary, let group = node.parallelGroupID else { return nil }
        return nodes.first { $0.id != node.id && $0.parallelGroupID == group
            && $0.type == (node.type == "parallel_start" ? "parallel_end" : "parallel_start")
        }
    }

    static func region(of node: WorkflowNodeModel, nodes: [WorkflowNodeModel], edges: [WorkflowEdgeModel]) -> Set<String> {
        guard let partner = partner(of: node, nodes: nodes) else { return [node.id] }
        let start = node.type == "parallel_start" ? node : partner
        let end = node.type == "parallel_end" ? node : partner
        var result: Set<String> = [end.id]
        var queue = [start.id]
        while let id = queue.popLast() {
            guard result.insert(id).inserted else { continue }
            queue += edges.filter { $0.source == id && !$0.isBackward }.map(\.target)
        }
        return result
    }

    static func status(of node: WorkflowNodeModel, run: WorkflowRunModel) -> String? {
        guard node.isParallelBoundary else { return nil }
        let key = node.type == "parallel_start" ? "split_id" : "join_id"
        let active = run.raw["joins"]?.objectValue?.values.contains { $0[key]?.stringValue == node.id } == true
        if active {
            if ["failed", "cancelled"].contains(run.status) { return run.status }
            return node.type == "parallel_start" ? "completed" : "waiting"
        }
        if run.raw["released_parallel_groups"]?.objectValue?.values.contains(where: { $0[key]?.stringValue == node.id }) == true {
            return "completed"
        }
        return nil
    }

}

// MARK: - WorkflowVM Parallel group

extension WorkflowVM {
    func addParallelGroup(at point: CGPoint?) {
        guard definition["routing_mode"]?.stringValue == "explicit" else {
            publishAlert("Convert existing parallel branches first", description:
                "This workflow uses inferred parallel branches. "
                    + "Convert its existing branches to explicit Parallel start/end pairs before adding another group.") {
                AlertAction(title: "OK")
            }
            return
        }
        let group = UUID().uuidString.lowercased()
        let origin = WorkflowCanvasGeometry.snapped(point ?? CGPoint(x: 80, y: 300))
        let pair: [JSONValue] = ["parallel_start", "parallel_end"].enumerated().map { index, type in
            .object([
                "id": .string(UUID().uuidString.lowercased()), "type": .string(type),
                "title": .string(WorkflowRole.title(type)), "parallel_group_id": .string(group),
                "position": .object(["x": .number(origin.x + CGFloat(index) * 560), "y": .number(origin.y)])
            ])
        }
        definition["nodes"] = .array((definition["nodes"]?.arrayValue ?? []) + pair)
        selectNodes(Set(pair.compactMap { $0["id"]?.stringValue }))
    }
}
