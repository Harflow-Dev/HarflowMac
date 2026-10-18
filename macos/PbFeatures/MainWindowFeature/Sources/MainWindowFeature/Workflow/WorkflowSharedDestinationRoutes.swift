import Foundation

// MARK: - WorkflowSharedDestinationRoutes

/// Plans a clear destination bus while retaining a complete path for every branch.
enum WorkflowSharedDestinationRoutes {
    static func routes(edges: [WorkflowRouteCache.Edge], nodes: [WorkflowConnectionRouter.Node],
                       occupied: [[CGPoint]]) -> [String: [CGPoint]] {
        let lookup = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let targetID = edges.first?.target, let target = lookup[targetID], edges.count >= 2 else { return [:] }
        let busX = floor((target.input.x - 20) / WorkflowCanvasGeometry.gridSpacing) * WorkflowCanvasGeometry.gridSpacing
        let eligible = edges.filter { edge in
            guard let source = lookup[edge.source], source.id != target.id else { return false }
            return busX - source.output.x >= 30
        }
        guard eligible.count >= 2 else { return [:] }
        let bodies = nodes.filter { $0.id != target.id }.map { $0.rectangle.insetBy(dx: -10, dy: -10) }
        let heads = occupied.compactMap { points -> CGRect? in
            guard let tip = points.last, tip != target.input else { return nil }
            return CGRect(x: tip.x - 9, y: tip.y - 7, width: 12, height: 14)
        }
        var candidates: [String: [CGPoint]] = [:]
        for edge in eligible {
            guard !Task.isCancelled else { return [:] }
            guard let source = lookup[edge.source] else { continue }
            let attachment = CGPoint(x: busX, y: source.output.y)
            let suffix = compact([attachment, CGPoint(x: busX, y: target.input.y), target.input])
            guard WorkflowConnectionRouter.clear(suffix, obstacles: bodies + heads) else { continue }
            let prefix = WorkflowConnectionRouter.route(source: source, target: nil, endpoint: attachment,
                                                        nodes: nodes, occupied: occupied)
            let route = compact(prefix + suffix.dropFirst())
            let otherBodies = nodes.filter { $0.id != source.id && $0.id != target.id }
                .map { $0.rectangle.insetBy(dx: -10, dy: -10) }
            let ownBodies = [source.rectangle, target.rectangle]
            guard route.first == source.output, route.last == target.input,
                  WorkflowConnectionRouter.clear(route, obstacles: otherBodies + ownBodies + heads),
                  hasCornerClearance(route) else { continue }
            candidates[edge.id] = route
        }
        return candidates.count >= 2 ? candidates : [:]
    }

    private static func compact(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for point in points {
            if result.last == point { continue }
            if result.count >= 2 {
                let previous = result[result.count - 2]
                let last = result[result.count - 1]
                if previous.x == last.x, last.x == point.x,
                   (last.y - previous.y) * (point.y - last.y) >= 0 {
                    result.removeLast()
                } else if previous.y == last.y, last.y == point.y,
                          (last.x - previous.x) * (point.x - last.x) >= 0 {
                    result.removeLast()
                }
            }
            result.append(point)
        }
        return result
    }

    private static func hasCornerClearance(_ points: [CGPoint]) -> Bool {
        // Two adjacent rounded bends need 20pt; terminal bends need the port/tip margin.
        guard points.count > 2 else { return true }
        return zip(points, points.dropFirst()).enumerated().allSatisfy { index, segment in
            let length = abs(segment.0.x - segment.1.x) + abs(segment.0.y - segment.1.y)
            return length >= (index == 0 ? 10 : index == points.count - 2 ? 17 : 20)
        }
    }
}
