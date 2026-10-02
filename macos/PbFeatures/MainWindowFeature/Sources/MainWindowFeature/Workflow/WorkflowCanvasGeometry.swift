import Foundation

// MARK: - WorkflowCanvasGeometry

enum WorkflowCanvasGeometry {
    static let gridSpacing: CGFloat = 10
    static let portOuterRadius: CGFloat = 5.25

    static func snapped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: max(0, (point.x / gridSpacing).rounded() * gridSpacing), y: max(0, (point.y / gridSpacing).rounded() * gridSpacing))
    }

    static func size(_ node: WorkflowNodeModel) -> CGSize {
        ["start", "end"].contains(node.type) ? CGSize(width: 72, height: 72) : CGSize(width: 200, height: 92)
    }

    static func center(_ node: WorkflowNodeModel) -> CGPoint {
        CGPoint(x: node.position.x + size(node).width / 2, y: node.position.y + size(node).height / 2)
    }

    static func input(_ node: WorkflowNodeModel) -> CGPoint { CGPoint(x: node.position.x, y: center(node).y) }
    static func output(_ node: WorkflowNodeModel) -> CGPoint { CGPoint(x: node.position.x + size(node).width, y: center(node).y) }

    static func connectionInput(_ node: WorkflowNodeModel, highlighted: Bool = false) -> CGPoint {
        let center = input(node)
        return CGPoint(x: center.x - (highlighted ? 6.75 : portOuterRadius), y: center.y)
    }

    static func connectionOutput(_ node: WorkflowNodeModel) -> CGPoint {
        let center = output(node)
        return CGPoint(x: center.x + portOuterRadius, y: center.y)
    }

    static func target(at point: CGPoint, sourceID: String, nodes: [WorkflowNodeModel]) -> WorkflowNodeModel? {
        nodes.filter { $0.id != sourceID && $0.type != "start" }
            .map { ($0, hypot(input($0).x - point.x, input($0).y - point.y)) }
            .filter { $0.1 <= 22 }
            .min { $0.1 < $1.1 }?
.0
    }
}

// MARK: - WorkflowConnectionDrag

struct WorkflowConnectionDrag: Equatable {
    let sourceID: String
    let location: CGPoint
}
