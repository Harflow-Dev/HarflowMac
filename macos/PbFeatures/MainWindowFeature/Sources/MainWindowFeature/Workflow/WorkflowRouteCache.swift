import Foundation

// MARK: - WorkflowRouteCache

@MainActor
final class WorkflowRouteCache {
    private struct Geometry: Equatable { let id: String; let rectangle: CGRect }
    private struct Key: Equatable {
        let sourceID: String
        let targetID: String?
        let endpoint: CGPoint
        let geometry: [Geometry]
    }

    private var entries: [String: (key: Key, points: [CGPoint])] = [:]
    private(set) var computationCount = 0

    func retain(ids: Set<String>) {
        entries = entries.filter { ids.contains($0.key) }
    }

    func route(id: String, source: WorkflowNodeModel, target: WorkflowNodeModel?, endpoint: CGPoint, nodes: [WorkflowNodeModel]) -> [CGPoint] {
        let key = Key(sourceID: source.id, targetID: target?.id, endpoint: endpoint,
                      geometry: nodes.map { Geometry(id: $0.id, rectangle: CGRect(origin: $0.position, size: WorkflowCanvasGeometry.size($0))) })
        if let entry = entries[id], entry.key == key { return entry.points }
        let points = WorkflowConnectionRouter.route(source: source, target: target, endpoint: endpoint, nodes: nodes)
        computationCount += 1
        entries[id] = (key, points)
        return points
    }
}
