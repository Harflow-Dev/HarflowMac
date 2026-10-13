import Foundation

// MARK: - WorkflowRouteCache

@MainActor
final class WorkflowRouteCache {
    private struct Geometry: Equatable { let id: String; let rectangle: CGRect }
    private struct EdgeGeometry: Equatable { let id: String; let source: String; let target: String }
    private struct BatchKey: Equatable { let geometry: [Geometry]; let edges: [EdgeGeometry] }
    private var batchKey: BatchKey?
    private var batch: [String: [CGPoint]] = [:]

    func routes(edges: [WorkflowEdgeModel], nodes: [WorkflowNodeModel]) -> [String: [CGPoint]] {
        let ordered = edges.sorted { $0.id < $1.id }
        let geometry = nodes.map { node in
            Geometry(id: node.id, rectangle: CGRect(origin: node.position, size: WorkflowCanvasGeometry.size(node)))
        }
.sorted { $0.id < $1.id }
        let key = BatchKey(geometry: geometry, edges: ordered.map { EdgeGeometry(id: $0.id, source: $0.source, target: $0.target) })
        if batchKey == key { return batch }
        var result: [String: [CGPoint]] = [:]
        // Protect every destination arrowhead before route ordering selects any strokes.
        var protectedTargets = Set<String>()
        var occupied: [[CGPoint]] = ordered.compactMap { edge in
            guard nodes.contains(where: { $0.id == edge.source }),
                  let target = nodes.first(where: { $0.id == edge.target }),
                  protectedTargets.insert(target.id).inserted else { return nil }
            return [WorkflowCanvasGeometry.connectionInput(target)]
        }
        for edge in ordered {
            guard let source = nodes.first(where: { $0.id == edge.source }), let target = nodes.first(where: { $0.id == edge.target }) else { continue }
            let points = WorkflowConnectionRouter.route(source: source, target: target,
                endpoint: WorkflowCanvasGeometry.connectionInput(target), nodes: nodes, occupied: occupied)
            result[edge.id] = points
            occupied.append(points)
            computationCount += 1
        }
        batchKey = key
        batch = result
        return result
    }

    func preview(source: WorkflowNodeModel, target: WorkflowNodeModel?, endpoint: CGPoint,
                 nodes: [WorkflowNodeModel], edges: [WorkflowEdgeModel]) -> [CGPoint] {
        let committed = routes(edges: edges, nodes: nodes)
        return WorkflowConnectionRouter.route(source: source, target: target, endpoint: endpoint,
            nodes: nodes, occupied: edges.sorted { $0.id < $1.id }.compactMap { committed[$0.id] })
    }

    private(set) var computationCount = 0

    func clear() {
        batchKey = nil
        batch = [:]
    }
}
