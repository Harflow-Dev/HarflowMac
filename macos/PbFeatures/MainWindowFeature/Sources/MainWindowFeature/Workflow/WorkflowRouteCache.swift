import Foundation
import Observation

// MARK: - WorkflowRouteCache

@MainActor @Observable
final class WorkflowRouteCache {
    struct Edge: Equatable, Sendable { let id: String; let source: String; let target: String }
    struct Snapshot: Equatable, Sendable {
        let nodes: [WorkflowConnectionRouter.Node]
        let edges: [Edge]
    }

    private(set) var batch: [String: [CGPoint]] = [:]
    private(set) var computationCount = 0
    @ObservationIgnored private var latest: Snapshot?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pending: (Snapshot, Int)?
    @ObservationIgnored private var worker: Task<[String: [CGPoint]]?, Never>?
    @ObservationIgnored private var completion: Task<Void, Never>?

    static func snapshot(edges: [WorkflowEdgeModel], nodes: [WorkflowNodeModel]) -> Snapshot {
        Snapshot(nodes: nodes.map(WorkflowConnectionRouter.snapshot).sorted { $0.id < $1.id },
                 edges: edges.map { Edge(id: $0.id, source: $0.source, target: $0.target) }.sorted { $0.id < $1.id })
    }

    func currentRoutes(for snapshot: Snapshot) -> [String: [CGPoint]] {
        let published = batch
        return snapshot == latest ? published : Self.provisional(snapshot)
    }

    func routes(edges: [WorkflowEdgeModel], nodes: [WorkflowNodeModel]) -> [String: [CGPoint]] {
        request(Self.snapshot(edges: edges, nodes: nodes))
        return batch
    }

    func request(_ snapshot: Snapshot) {
        guard snapshot != latest else { return }
        latest = snapshot
        generation += 1
        batch = Self.provisional(snapshot)
        pending = (snapshot, generation)
        worker?.cancel()
        startPending()
    }

    private func startPending() {
        guard worker == nil, let (snapshot, requestedGeneration) = pending else { return }
        pending = nil
        let task = Task.detached(priority: .userInitiated) { Self.compute(snapshot) }
        worker = task
        completion = Task { [weak self] in
            let result = await task.value
            guard let self else { return }
            worker = nil
            if generation == requestedGeneration, latest == snapshot, let result {
                batch = result
                computationCount += result.count
            }
            startPending()
        }
    }

    nonisolated static func compute(_ snapshot: Snapshot) -> [String: [CGPoint]]? {
        let nodes = Dictionary(snapshot.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [String: [CGPoint]] = [:]
        var protectedTargets = Set<String>()
        var occupied = snapshot.edges.compactMap { edge -> [CGPoint]? in
            guard nodes[edge.source] != nil, let target = nodes[edge.target], protectedTargets.insert(target.id).inserted else { return nil }
            return [target.input]
        }
        for edge in snapshot.edges {
            guard !Task.isCancelled else { return nil }
            guard let source = nodes[edge.source], let target = nodes[edge.target] else { continue }
            let points = WorkflowConnectionRouter.route(source: source, target: target, endpoint: target.input,
                                                       nodes: snapshot.nodes, occupied: occupied)
            guard !Task.isCancelled else { return nil }
            result[edge.id] = points
            occupied.append(points)
        }
        return result
    }

    private nonisolated static func provisional(_ snapshot: Snapshot) -> [String: [CGPoint]] {
        let nodes = Dictionary(snapshot.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return snapshot.edges.reduce(into: [:]) { routes, edge in
            guard let source = nodes[edge.source], let target = nodes[edge.target] else { return }
            routes[edge.id] = provisional(from: source.output, to: target.input)
        }
    }

    private nonisolated static func provisional(from start: CGPoint, to finish: CGPoint) -> [CGPoint] {
        if start.y == finish.y { return [start, finish] }
        let lane = finish.x > start.x ? (start.x + finish.x) / 2 : max(start.x, finish.x) + 20
        return [start, CGPoint(x: lane, y: start.y), CGPoint(x: lane, y: finish.y), finish]
    }

    func preview(source: WorkflowNodeModel, target: WorkflowNodeModel?, endpoint: CGPoint,
                 nodes: [WorkflowNodeModel], edges: [WorkflowEdgeModel]) -> [CGPoint] {
        Self.provisional(from: WorkflowCanvasGeometry.connectionOutput(source), to: endpoint)
    }

    /// Wait for the latest coalesced request; useful for deterministic verification without timers.
    func waitUntilSettled() async {
        while let completion { await completion.value; if worker == nil { return } }
    }

    func settledRoutes(edges: [WorkflowEdgeModel], nodes: [WorkflowNodeModel]) async -> [String: [CGPoint]] {
        _ = routes(edges: edges, nodes: nodes)
        await waitUntilSettled()
        return batch
    }

    func clear() {
        generation += 1
        latest = nil
        pending = nil
        batch = [:]
        worker?.cancel()
    }
}
