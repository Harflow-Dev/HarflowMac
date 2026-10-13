import Foundation

// MARK: - WorkflowConnectionApproach

/// Fan-in routes join a shared straight trunk before the arrowhead rather than turning across it.
enum WorkflowConnectionApproach {
    static func inset(for edge: WorkflowEdgeModel, edges: [WorkflowEdgeModel], nodes: [WorkflowNodeModel]) -> CGFloat {
        let sourceRows = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, WorkflowCanvasGeometry.center($0).y) })
        let incoming = edges.filter { $0.target == edge.target }.sorted {
            let left = sourceRows[$0.source] ?? 0
            let right = sourceRows[$1.source] ?? 0
            return left == right ? $0.id < $1.id : left < right
        }
        return 35 + CGFloat(incoming.firstIndex(where: { $0.id == edge.id }) ?? 0) * 20
    }
}
