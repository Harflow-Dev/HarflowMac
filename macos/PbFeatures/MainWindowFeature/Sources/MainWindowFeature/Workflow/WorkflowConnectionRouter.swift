import Foundation

// MARK: - WorkflowConnectionRouter

enum WorkflowConnectionRouter {
    private static let spacing = WorkflowCanvasGeometry.gridSpacing
    private static let clearance: CGFloat = 10
    private static let expansionLimit = 5000

    static func route(source: WorkflowNodeModel, target: WorkflowNodeModel?, endpoint: CGPoint, nodes: [WorkflowNodeModel]) -> [CGPoint] {
        let start = WorkflowCanvasGeometry.connectionOutput(source)
        let finish = endpoint
        let startGrid = CGPoint(x: ceil((start.x + 15) / spacing) * spacing, y: start.y)
        let finishGrid = CGPoint(x: floor((finish.x - 15) / spacing) * spacing, y: finish.y)
        let prefix = [start, startGrid]
        let suffix = [finishGrid, finish]
        let obstacles = nodes.map { node in
            (node.id, CGRect(origin: node.position, size: WorkflowCanvasGeometry.size(node)).insetBy(dx: -clearance, dy: -clearance))
        }
        let prefixClear = clear(prefix, obstacles: obstacles.filter { $0.0 != source.id }.map(\.1))
        let suffixClear = clear(suffix, obstacles: obstacles.filter { $0.0 != target?.id }.map(\.1))
        let rectangles = obstacles.map(\.1)
        if prefixClear, suffixClear, let middle = search(from: startGrid, to: finishGrid, obstacles: rectangles) {
            return simplified(prefix + middle + suffix)
        }
        // Overlapping boxes can make startPoint port corridor impossible. Keep the fallback finite and orthogonal.
        let rails = [max(0, floor(((rectangles.map(\.minY).min() ?? 0) - 20) / spacing) * spacing),
                     ceil(((rectangles.map(\.maxY).max() ?? 0) + 20) / spacing) * spacing]
        let candidates = rails.map { y in
            simplified(prefix + [CGPoint(x: startGrid.x, y: y), CGPoint(x: finishGrid.x, y: y)] + suffix)
        }
        let safe = candidates.filter { clear(Array($0.dropFirst().dropLast()), obstacles: rectangles) }
        return (safe.isEmpty ? candidates : safe).min {
            $0.count == $1.count ? length($0) < length($1) : $0.count < $1.count
        } ?? [start, finish]
    }

    static func labelPosition(_ points: [CGPoint]) -> CGPoint {
        let segment = zip(points, points.dropFirst()).max { pairA, pairB in
            distance(pairA.0, pairA.1) < distance(pairB.0, pairB.1)
        }
        guard let segment else { return points.first ?? .zero }
        return CGPoint(x: (segment.0.x + segment.1.x) / 2, y: (segment.0.y + segment.1.y) / 2)
    }

    static func clear(_ points: [CGPoint], obstacles: [CGRect]) -> Bool {
        zip(points, points.dropFirst()).allSatisfy { startPoint, endPoint in
            obstacles.allSatisfy { rectangle in
                if startPoint.y == endPoint.y {
                    return startPoint.y <= rectangle.minY || startPoint.y >= rectangle.maxY
                        || max(startPoint.x, endPoint.x) <= rectangle.minX || min(startPoint.x, endPoint.x) >= rectangle.maxX
                }
                return startPoint.x <= rectangle.minX || startPoint.x >= rectangle.maxX
                    || max(startPoint.y, endPoint.y) <= rectangle.minY || min(startPoint.y, endPoint.y) >= rectangle.maxY
            }
        }
    }

    private static func search(from start: CGPoint, to finish: CGPoint, obstacles: [CGRect]) -> [CGPoint]? {
        let coordinates = [start.x, start.y, finish.x, finish.y] + obstacles.flatMap { [$0.minX, $0.maxX, $0.minY, $0.maxY] }
        guard coordinates.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else { return nil }
        // Compress empty grid spans into visibility lanes. Exact port rows avoid tiny projection stair steps.
        let minX = min(0, start.x, finish.x)
        let minY = min(0, start.y, finish.y)
        let horizontal = obstacles.flatMap { [floor($0.minX / spacing) * spacing, ceil($0.maxX / spacing) * spacing] }
        let vertical = obstacles.flatMap { [floor($0.minY / spacing) * spacing, ceil($0.maxY / spacing) * spacing] }
        let xCoordinates = Array(Set(horizontal + [start.x, finish.x, minX])).filter { $0 >= minX }.sorted()
        let yCoordinates = Array(Set(vertical + [start.y, finish.y, minY])).filter { $0 >= minY }.sorted()
        guard let startX = xCoordinates.firstIndex(of: start.x), let startY = yCoordinates.firstIndex(of: start.y),
              let goalX = xCoordinates.firstIndex(of: finish.x), let goalY = yCoordinates.firstIndex(of: finish.y) else { return nil }
        let origin = GridState(x: startX, y: startY, direction: 0)
        let goal = GridPoint(x: goalX, y: goalY)
        return walk(origin: origin, goal: goal, xCoordinates: xCoordinates, yCoordinates: yCoordinates, obstacles: obstacles)
    }

    private static func walk(origin: GridState, goal: GridPoint, xCoordinates: [CGFloat], yCoordinates: [CGFloat],
                             obstacles: [CGRect]) -> [CGPoint]? {
        let start = CGPoint(x: xCoordinates[origin.x], y: yCoordinates[origin.y])
        let finish = CGPoint(x: xCoordinates[goal.x], y: yCoordinates[goal.y])
        func point(_ state: GridState) -> CGPoint { CGPoint(x: xCoordinates[state.x], y: yCoordinates[state.y]) }
        var frontier = RouteHeap()
        var serial = 0
        let zero = RouteCost(bends: 0, length: 0)
        var costs = [origin: zero]
        var parents: [GridState: GridState] = [:]
        var blocked: [GridPoint: Bool] = [:]
        func isBlocked(_ state: GridState) -> Bool {
            let key = GridPoint(x: state.x, y: state.y)
            if let value = blocked[key] { return value }
            let position = point(state)
            let value = obstacles.contains { position.x > $0.minX && position.x < $0.maxX && position.y > $0.minY && position.y < $0.maxY }
            blocked[key] = value
            return value
        }
        guard !isBlocked(origin), !isBlocked(GridState(x: goal.x, y: goal.y, direction: 0)) else { return nil }
        frontier.push(RouteEntry(state: origin, cost: zero, score: RouteCost(bends: 0, length: distance(start, finish)), serial: serial))
        let directions = [(1, 0), (0, -1), (0, 1), (-1, 0)]
        var expansions = 0
        var bestGoal: (state: GridState, cost: RouteCost)?
        while let entry = frontier.pop(), expansions < expansionLimit {
            guard costs[entry.state] == entry.cost else { continue }
            if let bestGoal, !entry.score.precedes(bestGoal.cost) { break }
            expansions += 1
            if entry.state.x == goal.x, entry.state.y == goal.y, entry.state.direction != 3 {
                let cost = RouteCost(bends: entry.cost.bends + (entry.state.direction == 0 ? 0 : 1), length: entry.cost.length)
                if bestGoal == nil || cost.precedes(bestGoal!.cost) { bestGoal = (entry.state, cost) }
                continue
            }
            for (direction, offset) in directions.enumerated() {
                let next = GridState(x: entry.state.x + offset.0, y: entry.state.y + offset.1, direction: direction)
                guard xCoordinates.indices.contains(next.x), yCoordinates.indices.contains(next.y), !isBlocked(next),
                      clear([point(entry.state), point(next)], obstacles: obstacles) else { continue }
                let cost = RouteCost(bends: entry.cost.bends + (entry.state.direction == direction ? 0 : 1),
                                     length: entry.cost.length + distance(point(entry.state), point(next)))
                guard costs[next].map({ cost.precedes($0) }) ?? true else { continue }
                costs[next] = cost
                parents[next] = entry.state
                serial += 1
                let score = RouteCost(bends: cost.bends, length: cost.length + distance(point(next), finish))
                frontier.push(RouteEntry(state: next, cost: cost, score: score, serial: serial))
            }
        }
        guard let bestGoal else { return nil }
        return reconstructed(bestGoal.state, parents: parents).map(point)
    }

    private static func reconstructed(_ goal: GridState, parents: [GridState: GridState]) -> [GridState] {
        var path = [goal]
        while let parent = parents[path.last!] { path.append(parent) }
        return path.reversed()
    }

    private static func simplified(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for point in points where point != result.last {
            if result.count >= 2 {
                let startPoint = result[result.count - 2]
                let endPoint = result[result.count - 1]
                if (startPoint.x == endPoint.x && endPoint.x == point.x) || (startPoint.y == endPoint.y && endPoint.y == point.y),
                   (endPoint.x - startPoint.x) * (point.x - endPoint.x) + (endPoint.y - startPoint.y) * (point.y - endPoint.y) >= 0 { result.removeLast() }
            }
            result.append(point)
        }
        return result
    }

    private static func distance(_ startPoint: CGPoint, _ endPoint: CGPoint) -> CGFloat { abs(startPoint.x - endPoint.x) + abs(startPoint.y - endPoint.y) }
    private static func length(_ points: [CGPoint]) -> CGFloat { zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) } }
}

// MARK: - Route search values

private struct GridPoint: Hashable { let x: Int; let y: Int }
private struct GridState: Hashable { let x: Int; let y: Int; let direction: Int }
private struct RouteCost: Equatable {
    let bends: Int
    let length: CGFloat
    func precedes(_ other: Self) -> Bool { bends == other.bends ? length < other.length : bends < other.bends }
}

private struct RouteEntry {
    let state: GridState
    let cost: RouteCost
    let score: RouteCost
    let serial: Int
    func precedes(_ other: Self) -> Bool { score == other.score ? serial < other.serial : score.precedes(other.score) }
}

private struct RouteHeap {
    private var values: [RouteEntry] = []
    mutating func push(_ entry: RouteEntry) {
        values.append(entry)
        var index = values.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard values[index].precedes(values[parent]) else { break }
            values.swapAt(index, parent)
            index = parent
        }
    }

    mutating func pop() -> RouteEntry? {
        guard !values.isEmpty else { return nil }
        if values.count == 1 { return values.removeLast() }
        let result = values[0]
        values[0] = values.removeLast()
        var index = 0
        while index * 2 + 1 < values.count {
            let left = index * 2 + 1
            let right = left + 1
            let child = right < values.count && values[right].precedes(values[left]) ? right : left
            guard values[child].precedes(values[index]) else { break }
            values.swapAt(index, child)
            index = child
        }
        return result
    }
}
