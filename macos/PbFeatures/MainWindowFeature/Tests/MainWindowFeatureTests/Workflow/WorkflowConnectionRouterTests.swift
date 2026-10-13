import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowConnectionRouterTests

@Suite struct WorkflowConnectionRouterTests {
    private func node(_ id: String, x: Double, y: Double, type: String = "agent") -> WorkflowNodeModel {
        WorkflowNodeModel(raw: ["id": .string(id), "type": .string(type), "position": .object(["x": .number(x), "y": .number(y)])])
    }

    @Test func givenABoxBetweenSteps_whenRouting_thenAvoidsBoxOnDeterministicGridLanes() {
        // given
        let source = node("source", x: 60, y: 100)
        let target = node("target", x: 660, y: 100)
        let obstacle = node("middle", x: 360, y: 100)
        let nodes = [source, obstacle, target]
        let endpoint = WorkflowCanvasGeometry.connectionInput(target)
        // when
        let route = WorkflowConnectionRouter.route(source: source, target: target, endpoint: endpoint, nodes: nodes)
        // then
        #expect(route == WorkflowConnectionRouter.route(source: source, target: target, endpoint: endpoint, nodes: nodes))
        #expect(route.count == 6) // The intervening box requires four bends.
        #expect(route.first == WorkflowCanvasGeometry.connectionOutput(source))
        #expect(route.last == endpoint)
        #expect(WorkflowConnectionRouter.clear(route, obstacles: [CGRect(origin: obstacle.position, size: WorkflowCanvasGeometry.size(obstacle))]))
        #expect(zip(route, route.dropFirst()).allSatisfy { $0.x == $1.x || $0.y == $1.y })
        #expect(route.dropFirst().dropLast().contains { $0.y.truncatingRemainder(dividingBy: 10) == 0 })
    }

    @Test func givenBackwardConnection_whenRouting_thenEscapesSourceAndApproachesInputFromLeft() {
        // given
        let source = node("source", x: 660, y: 100)
        let target = node("target", x: 60, y: 100)
        // when
        let route = WorkflowConnectionRouter.route(source: source, target: target,
                                                    endpoint: WorkflowCanvasGeometry.connectionInput(target), nodes: [source, target])
        // then
        #expect(route[1].x > route[0].x)
        #expect(route[route.count - 2].x < route.last!.x)
        #expect(route[route.count - 2].y == route.last!.y)
        #expect(WorkflowConnectionRouter.clear(route, obstacles: [
            CGRect(origin: source.position, size: WorkflowCanvasGeometry.size(source)),
            CGRect(origin: target.position, size: WorkflowCanvasGeometry.size(target))
        ]))
    }

    @Test func givenOverlappingBoxes_whenRouting_thenFallbackStaysFiniteAndOrthogonal() {
        // given
        let source = node("source", x: 60, y: 100)
        let target = node("target", x: 60, y: 100)
        // when
        let route = WorkflowConnectionRouter.route(source: source, target: target,
                                                    endpoint: WorkflowCanvasGeometry.connectionInput(target), nodes: [source, target])
        // then
        #expect(route.count < 12)
        #expect(route.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        #expect(zip(route, route.dropFirst()).allSatisfy { $0.x == $1.x || $0.y == $1.y })
        #expect(route.last == WorkflowCanvasGeometry.connectionInput(target))
    }

    @Test func givenPalette_whenPresentingSteps_thenLegacyWaitStepIsNotOffered() {
        // given / when / then
        #expect(!WorkflowRole.palette.contains("join"))
        #expect(WorkflowRole.title("join") == "Wait for all")
    }

    @Test func givenAlignedOffGridPorts_whenRouting_thenUsesOneStraightSegmentWithoutProjectionStairs() {
        // given
        let source = node("source", x: 60, y: 100)
        let target = node("target", x: 560, y: 100)
        // when
        let route = WorkflowConnectionRouter.route(source: source, target: target,
                                                    endpoint: WorkflowCanvasGeometry.connectionInput(target), nodes: [source, target])
        // then
        #expect(route == [WorkflowCanvasGeometry.connectionOutput(source), WorkflowCanvasGeometry.connectionInput(target)])
    }

    @Test func givenOffsetOffGridPorts_whenRouting_thenUsesMinimumTwoBendsWithoutTinyStairSegments() {
        // given
        let source = node("source", x: 60, y: 100)
        let target = node("target", x: 560, y: 240)
        // when
        let route = WorkflowConnectionRouter.route(source: source, target: target,
                                                    endpoint: WorkflowCanvasGeometry.connectionInput(target), nodes: [source, target])
        // then
        #expect(route.count == 4)
        #expect(route[1].x == route[2].x)
        #expect(route[1].y == route[0].y)
        #expect(route[2].y == route[3].y)
        #expect(route[1].x.truncatingRemainder(dividingBy: 10) == 0)
        #expect(zip(route, route.dropFirst()).allSatisfy { abs($0.x - $1.x) + abs($0.y - $1.y) >= 10 })
    }

    @Test(arguments: [35, 75] as [CGFloat])
    func givenSequentialNodesWithReturnEdge_whenRouting_thenFinalApproachClearsArrowheadAndRoundedCorner(approachInset: CGFloat) {
        // given
        let target = node("target", x: 60, y: 100)
        let middle = node("middle", x: 360, y: 100)
        let source = node("source", x: 660, y: 100)
        let endpoint = WorkflowCanvasGeometry.connectionInput(target)
        // when
        let route = WorkflowConnectionRouter.route(source: source, target: target, endpoint: endpoint,
                                                    nodes: [target, middle, source], approachInset: approachInset)
        // then
        #expect(route.last == endpoint)
        #expect(route.allSatisfy { $0.x >= 0 })
        #expect(endpoint.x - route[route.count - 2].x >= 35)
        #expect(route[route.count - 2].y == endpoint.y)
        #expect(WorkflowConnectionRouter.clear(route, obstacles: [CGRect(origin: middle.position, size: WorkflowCanvasGeometry.size(middle))]))
    }

    @Test func givenParallelFanIn_whenRouting_thenApproachesAreOrderedAndArrowheadCorridorStaysClear() {
        // given
        let sources = [node("upper", x: 60, y: 60), node("center", x: 60, y: 220), node("lower", x: 60, y: 380)]
        let target = node("target", x: 560, y: 220)
        let nodes = sources + [target]
        let edges = sources.map { WorkflowEdgeModel(raw: ["id": .string($0.id), "source": .string($0.id), "target": .string(target.id)]) }
        let endpoint = WorkflowCanvasGeometry.connectionInput(target)
        // when
        let insets = edges.map { WorkflowConnectionApproach.inset(for: $0, edges: edges, nodes: nodes) }
        let routes = zip(sources, insets).map {
            WorkflowConnectionRouter.route(source: $0, target: target, endpoint: endpoint, nodes: nodes, approachInset: $1)
        }
        // then
        #expect(insets == [35, 55, 75])
        #expect(edges.map { WorkflowConnectionApproach.inset(for: $0, edges: edges.reversed(), nodes: nodes) } == insets)
        for route in routes {
           #expect(route.last == endpoint)
            #expect(endpoint.x - route[route.count - 2].x >= 35)
            #expect(route[route.count - 2].y == endpoint.y)
            #expect(WorkflowConnectionRouter.clear(Array(route.dropFirst()), obstacles: [
                CGRect(origin: target.position, size: WorkflowCanvasGeometry.size(target))
            ]))
        }
    }

    @Test(arguments: [35, 55, 75] as [CGFloat])
    func givenFanInWithPrecedingColumnNeighbor_whenRouting_thenFitsApproachInsideClearCorridor(approachInset: CGFloat) {
        // given: an offset source and a neighboring step in the preceding default column.
        let source = node("source", x: 40, y: 40)
        let neighbor = node("neighbor", x: 300, y: 220)
        let target = node("target", x: 560, y: 220)
        let endpoint = WorkflowCanvasGeometry.connectionInput(target)
        let paddedNeighbor = CGRect(origin: neighbor.position, size: WorkflowCanvasGeometry.size(neighbor))
            .insetBy(dx: -20, dy: -20)
        // when
        let route = WorkflowConnectionRouter.route(source: source, target: target, endpoint: endpoint,
                                                    nodes: [source, neighbor, target], approachInset: approachInset)
        // then
        #expect(route.first == WorkflowCanvasGeometry.connectionOutput(source))
        #expect(route.last == endpoint)
        #expect(WorkflowConnectionRouter.clear(route, obstacles: [paddedNeighbor]))
        #expect(zip(route, route.dropFirst()).allSatisfy { $0.x == $1.x || $0.y == $1.y })
        #expect(route[route.count - 2].y == endpoint.y)
        #expect(endpoint.x - route[route.count - 2].x >= 17)
    }

    @MainActor @Test func givenCachedFanInRoute_whenApproachOrTargetMoves_thenRecomputesAndRemainsAttached() {
        // given
        let source = node("source", x: 60, y: 100)
        var target = node("target", x: 560, y: 240)
        let cache = WorkflowRouteCache()
        let endpoint = WorkflowCanvasGeometry.connectionInput(target)
        _ = cache.route(id: "edge", source: source, target: target, endpoint: endpoint, nodes: [source, target], approachInset: 35)
        // when
        _ = cache.route(id: "edge", source: source, target: target, endpoint: endpoint, nodes: [source, target], approachInset: 75)
        target.raw["position"] = .object(["x": .number(720), "y": .number(320)])
        let movedEndpoint = WorkflowCanvasGeometry.connectionInput(target)
        let route = cache.route(id: "edge", source: source, target: target, endpoint: movedEndpoint, nodes: [source, target], approachInset: 75)
        // then
        #expect(cache.computationCount == 3)
        #expect(route.last == movedEndpoint)
        #expect(movedEndpoint.x - route[route.count - 2].x >= 75)
    }

    @Test(arguments: ["start", "agent"])
    func givenStarterNodesWithFiftyPointGap_whenRouting_thenUsesDirectAttachedConnection(sourceType: String) {
        // given
        let source = sourceType == "start"
            ? node("source", x: 68, y: 110, type: "start")
            : node("source", x: 190, y: 100)
        let target = node("target", x: sourceType == "start" ? 190 : 440, y: 100)
        let start = WorkflowCanvasGeometry.connectionOutput(source)
        let endpoint = WorkflowCanvasGeometry.connectionInput(target)
        // when
        let route = WorkflowConnectionRouter.route(source: source, target: target, endpoint: endpoint, nodes: [source, target])
        // then
        #expect(start.y == 146)
        #expect(endpoint.y == 146)
        #expect(route == [start, endpoint])
        #expect(endpoint.x - start.x == 39.5)
    }

    @Test func givenDefaultAgentAndEndPositions_whenRouting_thenUsesTwoBendsWithinShortForwardGap() {
        // given: validate_definition assigns successive nodes x = 80 + 260 * index, y = 80.
        let source = node("work", x: 340, y: 80)
        let target = node("end", x: 600, y: 80, type: "end")
        let start = WorkflowCanvasGeometry.connectionOutput(source)
        let endpoint = WorkflowCanvasGeometry.connectionInput(target)
        // when
        let route = WorkflowConnectionRouter.route(source: source, target: target, endpoint: endpoint, nodes: [source, target])
        // then
        #expect(route.count == 4)
        #expect(route.first == start)
        #expect(route.last == endpoint)
        #expect(route.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.y >= endpoint.y && $0.y <= start.y })
        #expect(zip(route, route.dropFirst()).allSatisfy { $0.x == $1.x || $0.y == $1.y })
        #expect(endpoint.x - route[route.count - 2].x >= 17)
        #expect(WorkflowConnectionRouter.clear(route, obstacles: [
            CGRect(origin: source.position, size: WorkflowCanvasGeometry.size(source)),
            CGRect(origin: target.position, size: WorkflowCanvasGeometry.size(target))
        ]))
    }

    @Test func givenAlignedNodesWithInterveningBox_whenConsideringDirectConnection_thenStillRoutesAroundObstacle() {
        // given
        let source = node("source", x: 190, y: 100)
        let obstacle = node("obstacle", x: 440, y: 100)
        let target = node("target", x: 690, y: 100)
        let endpoint = WorkflowCanvasGeometry.connectionInput(target)
        // when
        let route = WorkflowConnectionRouter.route(source: source, target: target, endpoint: endpoint, nodes: [source, obstacle, target])
        // then
        #expect(route.count > 2)
        #expect(route.last == endpoint)
        #expect(WorkflowConnectionRouter.clear(route, obstacles: [CGRect(origin: obstacle.position, size: WorkflowCanvasGeometry.size(obstacle))]))
    }

}
