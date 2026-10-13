import Foundation

// MARK: - WorkflowConnectionRouter

enum WorkflowConnectionRouter {
    private static let spacing = WorkflowCanvasGeometry.gridSpacing
    // Other routes stay outside the destination arrowhead (7pt) and port rim.
    private static let clearance: CGFloat = 10
    private static let expansionLimit = 5000

    struct Node: Equatable, Sendable {
        let id: String
        let rectangle: CGRect
        let input: CGPoint
        let output: CGPoint
        var position: CGPoint { rectangle.origin }
    }

    static func snapshot(_ node: WorkflowNodeModel) -> Node {
        Node(id: node.id, rectangle: CGRect(origin: node.position, size: WorkflowCanvasGeometry.size(node)),
             input: WorkflowCanvasGeometry.connectionInput(node), output: WorkflowCanvasGeometry.connectionOutput(node))
    }

    static func route(source: WorkflowNodeModel, target: WorkflowNodeModel?, endpoint: CGPoint,
                      nodes: [WorkflowNodeModel], occupied: [[CGPoint]] = []) -> [CGPoint] {
        route(source: snapshot(source), target: target.map(snapshot), endpoint: endpoint,
              nodes: nodes.map(snapshot), occupied: occupied)
    }

    static func route(source: Node, target: Node?, endpoint: CGPoint,
                      nodes: [Node], occupied: [[CGPoint]] = []) -> [CGPoint] {
        guard !Task.isCancelled else { return [] }
        let start = source.output
        let finish = endpoint
        // An aligned short gap needs no bend corridor. Its approach anchor could otherwise
        // land inside the source's clearance rectangle and force an unnecessary return loop.
        let directObstacles = nodes.filter { $0.id != source.id && $0.id != target?.id }.map {
            $0.rectangle.insetBy(dx: -clearance, dy: -clearance)
        }
        let direct = start.y == finish.y && finish.x > start.x && clear([start, finish], obstacles: directObstacles)
        if direct, occupancyCost(from: start, to: finish, occupied: occupied) == 0 {
            return [start, finish]
        }
        let startGrid = CGPoint(x: ceil((start.x + 10) / spacing) * spacing, y: start.y)
        // Reserve the local rounded bend and arrowhead, without expanding fan-in lanes.
        // Keep fan-in lanes on the canvas when the destination is close to its leading edge.
        let inset = CGFloat(20)
        var finishGrid = CGPoint(x: floor((finish.x - inset) / spacing) * spacing, y: finish.y)
        let sourceObstacle = source.rectangle
            .insetBy(dx: -clearance, dy: -clearance)
        let sourceExit = max(startGrid.x, ceil(sourceObstacle.maxX / spacing) * spacing)
        // Short forward gaps can place the approach anchor inside the source's padding.
        // Bound it to the exit lane while retaining room for the 10pt bend and 7pt tip.
        if finish.x > start.x, finish.y > sourceObstacle.minY, finish.y < sourceObstacle.maxY,
           finishGrid.x < sourceExit, finish.x - sourceExit >= 17 {
            finishGrid.x = sourceExit
        }
        let prefix = [start, startGrid]
        let obstacles = nodes.map { node in
            (node.id, node.rectangle.insetBy(dx: -clearance, dy: -clearance))
        }
        // Fan-in lanes share the available corridor with every preceding node, not just
        // their source. Shorten an approach when its anchor would enter another box.
        let approachObstacles = obstacles.filter { $0.0 != target?.id }.map(\.1)
        if let corridorEdge = approachObstacles.filter({ rectangle in
            finish.y > rectangle.minY && finish.y < rectangle.maxY
                && rectangle.minX < finish.x && rectangle.maxX > finishGrid.x
        })
.map(\.maxX)
.max() {
            let safeAnchor = ceil(corridorEdge / spacing) * spacing
            if finish.x - safeAnchor >= 17 { finishGrid.x = max(finishGrid.x, safeAnchor) }
        }
        let suffix = [finishGrid, finish]
        let prefixClear = clear(prefix, obstacles: obstacles.filter { $0.0 != source.id }.map(\.1))
        let suffixClear = clear(suffix, obstacles: obstacles.filter { $0.0 != target?.id }.map(\.1))
        let rectangles = obstacles.map(\.1)
        if prefixClear, suffixClear, let middle = search(from: startGrid, to: finishGrid, obstacles: rectangles, occupied: occupied,
                                                        sourceBoundary: finish.x >= source.position.x ? source.position.x : nil) {
            let routed = simplified(prefix + middle + suffix)
            if direct, routeCost([start, finish], occupied: occupied) <= routeCost(routed, occupied: occupied) { return [start, finish] }
            return routed
        }
        // Overlapping boxes can make startPoint port corridor impossible. Keep the fallback finite and orthogonal.
        let rails = [max(0, floor(((rectangles.map(\.minY).min() ?? 0) - 20) / spacing) * spacing),
                     ceil(((rectangles.map(\.maxY).max() ?? 0) + 20) / spacing) * spacing]
        let candidates = rails.map { y in
            simplified(prefix + [CGPoint(x: startGrid.x, y: y), CGPoint(x: finishGrid.x, y: y)] + suffix)
        }
        let safe = candidates.filter { clear(Array($0.dropFirst().dropLast()), obstacles: rectangles) }
        return (safe.isEmpty ? candidates : safe).min {
            routeCost($0, occupied: occupied) < routeCost($1, occupied: occupied)
        } ?? [start, finish]
    }

    private static func routeCost(_ points: [CGPoint], occupied: [[CGPoint]]) -> CGFloat {
        length(points) + CGFloat(max(0, points.count - 2)) * 12
            + zip(points, points.dropFirst()).reduce(0) { $0 + occupancyCost(from: $1.0, to: $1.1, occupied: occupied) }
    }

    /// Occupancy is a preference: tight corridors can share same-direction strokes.
    static func occupancyCost(from start: CGPoint, to finish: CGPoint, occupied: [[CGPoint]]) -> CGFloat {
        occupancyCost(from: start, to: finish, occupancy: Occupancy(paths: occupied))
    }

    private static func occupancyCost(from start: CGPoint, to finish: CGPoint, occupancy: Occupancy) -> CGFloat {
        let horizontal = start.y == finish.y
        let low = min(horizontal ? start.x : start.y, horizontal ? finish.x : finish.y)
        let high = max(horizontal ? start.x : start.y, horizontal ? finish.x : finish.y)
        let parallel = horizontal ? occupancy.horizontal[start.y] : occupancy.vertical[start.x]
        var cost: CGFloat = 0
        for segment in parallel ?? [] {
            let overlap = max(0, min(high, segment.high) - max(low, segment.low))
            let forward = horizontal ? finish.x > start.x : finish.y > start.y
            cost += overlap * (forward == segment.forward ? 0.5 : 4)
        }
        let crossedCoordinates = Occupancy.selected(horizontal ? occupancy.columns : occupancy.rows, low: low, high: high)
        let perpendicular = horizontal ? occupancy.vertical : occupancy.horizontal
        let fixed = horizontal ? start.y : start.x
        for coordinate in crossedCoordinates {
            for segment in perpendicular[coordinate] ?? [] where fixed >= segment.low && fixed <= segment.high { cost += 4 }
        }
        let tipCoordinates = Occupancy.selected(horizontal ? occupancy.tipRows : occupancy.tipColumns,
            low: horizontal ? start.y - 7 : start.x - 3, high: horizontal ? start.y + 7 : start.x + 9)
        let tipIndex = horizontal ? occupancy.tipsByRow : occupancy.tipsByColumn
        for coordinate in tipCoordinates {
            for tip in tipIndex[coordinate] ?? [] {
                if horizontal, finish.x > start.x, start.y == tip.y, finish.x <= tip.x { continue }
                let intersects = horizontal
                    ? start.y > tip.y - 7 && start.y < tip.y + 7 && high > tip.x - 9 && low < tip.x + 3
                    : start.x > tip.x - 9 && start.x < tip.x + 3 && high > tip.y - 7 && low < tip.y + 7
                if intersects { cost += 160 }
            }
        }
        return cost
    }

    private struct Occupancy {
        struct Segment { let low: CGFloat; let high: CGFloat; let forward: Bool }
        let horizontal: [CGFloat: [Segment]]
        let vertical: [CGFloat: [Segment]]
        let rows: [CGFloat]
        let columns: [CGFloat]
        let tipsByRow: [CGFloat: [CGPoint]]
        let tipsByColumn: [CGFloat: [CGPoint]]
        let tipRows: [CGFloat]
        let tipColumns: [CGFloat]

        init(paths: [[CGPoint]]) {
            var horizontal: [CGFloat: [Segment]] = [:]
            var vertical: [CGFloat: [Segment]] = [:]
            var tipsByRow: [CGFloat: [CGPoint]] = [:]
            var tipsByColumn: [CGFloat: [CGPoint]] = [:]
            for path in paths {
                for (startPoint, endPoint) in zip(path, path.dropFirst()) {
                    if startPoint.y == endPoint.y {
                        horizontal[startPoint.y, default: []].append(Segment(
                            low: min(startPoint.x, endPoint.x), high: max(startPoint.x, endPoint.x), forward: endPoint.x > startPoint.x
                        ))
                    } else {
                        vertical[startPoint.x, default: []].append(Segment(
                            low: min(startPoint.y, endPoint.y), high: max(startPoint.y, endPoint.y), forward: endPoint.y > startPoint.y
                        ))
                    }
                }
                if let tip = path.last {
                    tipsByRow[tip.y, default: []].append(tip)
                    tipsByColumn[tip.x, default: []].append(tip)
                }
            }
            self.horizontal = horizontal
            self.vertical = vertical
            self.rows = horizontal.keys.sorted()
            self.columns = vertical.keys.sorted()
            self.tipsByRow = tipsByRow
            self.tipsByColumn = tipsByColumn
            self.tipRows = tipsByRow.keys.sorted()
            self.tipColumns = tipsByColumn.keys.sorted()
        }

        static func selected(_ coordinates: [CGFloat], low: CGFloat, high: CGFloat) -> ArraySlice<CGFloat> {
            var lower = 0
            var upper = coordinates.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if coordinates[middle] < low { lower = middle + 1 } else { upper = middle }
            }
            let start = lower
            upper = coordinates.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if coordinates[middle] <= high { lower = middle + 1 } else { upper = middle }
            }
            return coordinates[start ..< lower]
        }
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

    private static func search(from start: CGPoint, to finish: CGPoint, obstacles: [CGRect], occupied: [[CGPoint]],
                               sourceBoundary: CGFloat?) -> [CGPoint]? {
        let coordinates = [start.x, start.y, finish.x, finish.y] + obstacles.flatMap { [$0.minX, $0.maxX, $0.minY, $0.maxY] }
        guard coordinates.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else { return nil }
        // Compress empty grid spans into visibility lanes. Exact port rows avoid tiny projection stair steps.
        let minX = min(0, start.x, finish.x)
        let minY = min(0, start.y, finish.y)
        let horizontal = obstacles.flatMap { [floor($0.minX / spacing) * spacing, ceil($0.maxX / spacing) * spacing] }
        let vertical = obstacles.flatMap { [floor($0.minY / spacing) * spacing, ceil($0.maxY / spacing) * spacing] }
        let occupiedX = occupied.flatMap { $0.flatMap { [floor($0.x / spacing) * spacing - spacing, ceil($0.x / spacing) * spacing + spacing] } }
        let occupiedY = occupied.flatMap { $0.flatMap { [floor($0.y / spacing) * spacing - spacing, ceil($0.y / spacing) * spacing + spacing] } }
        let xCoordinates = Array(Set(horizontal + occupiedX + [start.x, finish.x, minX])).filter { $0 >= minX }.sorted()
        let yCoordinates = Array(Set(vertical + occupiedY + [start.y, finish.y, minY])).filter { $0 >= minY }.sorted()
        guard let startX = xCoordinates.firstIndex(of: start.x), let startY = yCoordinates.firstIndex(of: start.y),
              let goalX = xCoordinates.firstIndex(of: finish.x), let goalY = yCoordinates.firstIndex(of: finish.y) else { return nil }
        let origin = GridState(x: startX, y: startY, direction: 0)
        let goal = GridPoint(x: goalX, y: goalY)
        let space = SearchSpace(xCoordinates: xCoordinates, yCoordinates: yCoordinates, obstacles: obstacles,
                                occupancy: Occupancy(paths: occupied), sourceBoundary: sourceBoundary)
        return walk(origin: origin, goal: goal, space: space)
    }

    private static func nextEntry(from frontier: inout RouteHeap) -> RouteEntry? {
        Task.isCancelled ? nil : frontier.pop()
    }

    private static func walk(origin: GridState, goal: GridPoint, space: SearchSpace) -> [CGPoint]? {
        let xCoordinates = space.xCoordinates
        let yCoordinates = space.yCoordinates
        let obstacles = space.obstacles
        let start = CGPoint(x: xCoordinates[origin.x], y: yCoordinates[origin.y])
        let finish = CGPoint(x: xCoordinates[goal.x], y: yCoordinates[goal.y])
        func point(_ state: GridState) -> CGPoint { CGPoint(x: xCoordinates[state.x], y: yCoordinates[state.y]) }
        var frontier = RouteHeap()
        var serial = 0
        let zero = RouteCost(value: 0)
        var costs = [origin: zero]
        var parents: [GridState: GridState] = [:]
        var blocked: [GridPoint: Bool] = [:]
        var transitions: [GridSegment: CGFloat] = [:]
        func isBlocked(_ state: GridState) -> Bool {
            let key = GridPoint(x: state.x, y: state.y)
            if let value = blocked[key] { return value }
            let position = point(state)
            let value = obstacles.contains { position.x > $0.minX && position.x < $0.maxX && position.y > $0.minY && position.y < $0.maxY }
            blocked[key] = value
            return value
        }
        guard !isBlocked(origin), !isBlocked(GridState(x: goal.x, y: goal.y, direction: 0)) else { return nil }
        frontier.push(RouteEntry(state: origin, cost: zero, score: RouteCost(value: distance(start, finish)), serial: serial))
        let directions = [(1, 0), (0, -1), (0, 1), (-1, 0)]
        var expansions = 0
        var bestGoal: (state: GridState, cost: RouteCost)?
        while let entry = nextEntry(from: &frontier), expansions < expansionLimit {
            guard costs[entry.state] == entry.cost else { continue }
            if let bestGoal, !entry.score.precedes(bestGoal.cost) { break }
            expansions += 1
            if entry.state.x == goal.x, entry.state.y == goal.y, entry.state.direction != 3 {
                let cost = RouteCost(value: entry.cost.value + (entry.state.direction == 0 ? 0 : 12))
                bestGoal = preferredGoal(state: entry.state, cost: cost, current: bestGoal)
                continue
            }
            for (direction, offset) in directions.enumerated() {
                let next = GridState(x: entry.state.x + offset.0, y: entry.state.y + offset.1, direction: direction)
                guard xCoordinates.indices.contains(next.x), yCoordinates.indices.contains(next.y), !isBlocked(next) else { continue }
                let movement = movementCost(from: entry.state, to: next, space: space, cache: &transitions)
                guard movement >= 0 else { continue }
                let cost = RouteCost(value: entry.cost.value + (entry.state.direction == direction ? 0 : 12) + movement)
                guard costs[next].map({ cost.precedes($0) }) ?? true else { continue }
                costs[next] = cost
                parents[next] = entry.state
                serial += 1
                let score = RouteCost(value: cost.value + distance(point(next), finish))
                frontier.push(RouteEntry(state: next, cost: cost, score: score, serial: serial))
            }
        }
        guard let bestGoal else { return nil }
        return reconstructed(bestGoal.state, parents: parents).map(point)
    }

    private static func preferredGoal(state: GridState, cost: RouteCost,
                                      current: (state: GridState, cost: RouteCost)?) -> (state: GridState, cost: RouteCost) {
        if let current, !cost.precedes(current.cost) { return current }
        return (state, cost)
    }

    private struct SearchSpace {
        let xCoordinates: [CGFloat]
        let yCoordinates: [CGFloat]
        let obstacles: [CGRect]
        let occupancy: Occupancy
        let sourceBoundary: CGFloat?

        // A small finite charge favors looping around the destination when its input
        // is still ahead of the source body. Truly backward destinations remain unpenalized.
        func sourceLoopCost(from start: CGPoint, to finish: CGPoint) -> CGFloat {
            guard let sourceBoundary else { return 0 }
            let crossesBoundary = (start.x < sourceBoundary) != (finish.x < sourceBoundary)
            return crossesBoundary ? spacing * 4 : 0
        }

        func point(_ state: GridState) -> CGPoint {
            CGPoint(x: xCoordinates[state.x], y: yCoordinates[state.y])
        }
    }

    private static func movementCost(from start: GridState, to finish: GridState,
                                     space: SearchSpace, cache: inout [GridSegment: CGFloat]) -> CGFloat {
        let segment = GridSegment(start: GridPoint(x: start.x, y: start.y), finish: GridPoint(x: finish.x, y: finish.y))
        if let cached = cache[segment] { return cached }
        let startPoint = space.point(start)
        let endPoint = space.point(finish)
        let movement = clear([startPoint, endPoint], obstacles: space.obstacles)
            ? distance(startPoint, endPoint) + occupancyCost(from: startPoint, to: endPoint, occupancy: space.occupancy)
                + space.sourceLoopCost(from: startPoint, to: endPoint) : -1
        cache[segment] = movement
        return movement
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
private struct GridSegment: Hashable { let start: GridPoint; let finish: GridPoint }
private struct GridState: Hashable { let x: Int; let y: Int; let direction: Int }
private struct RouteCost: Equatable {
    let value: CGFloat
    func precedes(_ other: Self) -> Bool { value < other.value }
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
