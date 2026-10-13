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

    @Test
    func givenSequentialNodesWithReturnEdge_whenRouting_thenFinalApproachClearsArrowheadAndRoundedCorner() {
        // given
        let target = node("target", x: 60, y: 100)
        let middle = node("middle", x: 360, y: 100)
        let source = node("source", x: 660, y: 100)
        let endpoint = WorkflowCanvasGeometry.connectionInput(target)
        // when
        let route = WorkflowConnectionRouter.route(source: source, target: target, endpoint: endpoint,
                                                    nodes: [target, middle, source])
        // then
        #expect(route.last == endpoint)
        #expect(route.allSatisfy { $0.x >= 0 })
        #expect(endpoint.x - route[route.count - 2].x >= 17)
        #expect(route[route.count - 2].y == endpoint.y)
        #expect(WorkflowConnectionRouter.clear(route, obstacles: [CGRect(origin: middle.position, size: WorkflowCanvasGeometry.size(middle))]))
    }

    @Test func givenParallelFanIn_whenRouting_thenLocalApproachKeepsArrowheadCorridorClear() {
        // given
        let sources = [node("upper", x: 60, y: 60), node("center", x: 60, y: 220), node("lower", x: 60, y: 380)]
        let target = node("target", x: 560, y: 220)
        let nodes = sources + [target]
        let endpoint = WorkflowCanvasGeometry.connectionInput(target)
        // when
        let routes = sources.map {
            WorkflowConnectionRouter.route(source: $0, target: target, endpoint: endpoint, nodes: nodes)
        }
        // then
        for route in routes {
           #expect(route.last == endpoint)
            #expect(endpoint.x - route[route.count - 2].x >= 17)
            #expect(route[route.count - 2].y == endpoint.y)
            #expect(WorkflowConnectionRouter.clear(Array(route.dropFirst()), obstacles: [
                CGRect(origin: target.position, size: WorkflowCanvasGeometry.size(target))
            ]))
        }
    }

    @Test
    func givenFanInWithPrecedingColumnNeighbor_whenRouting_thenFitsApproachInsideClearCorridor() {
        // given: an offset source and a neighboring step in the preceding default column.
        let source = node("source", x: 40, y: 40)
        let neighbor = node("neighbor", x: 300, y: 220)
        let target = node("target", x: 560, y: 220)
        let endpoint = WorkflowCanvasGeometry.connectionInput(target)
        let paddedNeighbor = CGRect(origin: neighbor.position, size: WorkflowCanvasGeometry.size(neighbor))
            .insetBy(dx: -10, dy: -10)
        // when
        let route = WorkflowConnectionRouter.route(source: source, target: target, endpoint: endpoint,
                                                    nodes: [source, neighbor, target])
        // then
        #expect(route.first == WorkflowCanvasGeometry.connectionOutput(source))
        #expect(route.last == endpoint)
        #expect(WorkflowConnectionRouter.clear(route, obstacles: [paddedNeighbor]))
        #expect(zip(route, route.dropFirst()).allSatisfy { $0.x == $1.x || $0.y == $1.y })
        #expect(route[route.count - 2].y == endpoint.y)
        #expect(endpoint.x - route[route.count - 2].x >= 17)
    }

    @MainActor @Test func givenCachedRoute_whenTargetMoves_thenRecomputesAndRemainsAttached() {
        // given
        let source = node("source", x: 60, y: 100)
        var target = node("target", x: 560, y: 240)
        let cache = WorkflowRouteCache()
        let edge = WorkflowEdgeModel(raw: ["id": .string("edge"), "source": .string(source.id), "target": .string(target.id)])
        _ = cache.routes(edges: [edge], nodes: [source, target])["edge"]!
        // when
        _ = cache.routes(edges: [edge], nodes: [source, target])["edge"]!
        target.raw["position"] = .object(["x": .number(720), "y": .number(320)])
        let movedEndpoint = WorkflowCanvasGeometry.connectionInput(target)
        let route = cache.routes(edges: [edge], nodes: [source, target])["edge"]!
        // then
        #expect(cache.computationCount == 2)
        #expect(route.last == movedEndpoint)
        #expect(movedEndpoint.x - route[route.count - 2].x >= 17)
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

    @Test func givenScreenshotReturnConnection_whenRouting_thenUsesNearbyApproachWithoutFanInExpansion() {
        // given
        let prepare = node("prepare", x: 170, y: 30)
        let plan = node("plan", x: 250, y: 170)
        let review = node("review", x: 500, y: 170)
        let baseline = node("baseline", x: 600, y: 310)
        let nodes = [prepare, plan, review, baseline]
        // when
        let route = WorkflowConnectionRouter.route(source: review, target: plan,
            endpoint: WorkflowCanvasGeometry.connectionInput(plan), nodes: nodes)
        // then
        #expect(route.map(\.x).min()! >= 210)
        #expect(route.map(\.x).max()! <= 730)
        #expect(route.map(\.y).min()! >= 150)
        #expect(route.last == WorkflowCanvasGeometry.connectionInput(plan))
    }

    @Test(arguments: [false, true]) func givenOccupiedAlignedLane_whenRouting_thenUsesNearbySeparateLane(opposing: Bool) {
        // given
        let source = node("source", x: 60, y: 100)
        let target = node("target", x: 560, y: 100)
        let start = WorkflowCanvasGeometry.connectionOutput(source)
        let finish = WorkflowCanvasGeometry.connectionInput(target)
        let occupied = opposing ? [[finish, start]] : [[start, finish]]
        // when
        let route = WorkflowConnectionRouter.route(source: source, target: target, endpoint: finish,
            nodes: [source, target], occupied: occupied)
        // then
        #expect(route.count > 2)
        #expect(route.contains { abs($0.y - start.y) <= 20 && $0.y != start.y })
        #expect(route.first == start)
        #expect(route.last == finish)
    }

    @Test func givenSharedLane_whenScoring_thenOpposingTrafficAndArrowheadCrossingAreMoreCostly() {
        // given
        let path = [CGPoint(x: 20, y: 40), CGPoint(x: 220, y: 40)]
        // when
        let same = WorkflowConnectionRouter.occupancyCost(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 180, y: 40), occupied: [path])
        let opposite = WorkflowConnectionRouter.occupancyCost(from: CGPoint(x: 180, y: 40), to: CGPoint(x: 40, y: 40), occupied: [path])
        let ordinaryCrossing = WorkflowConnectionRouter.occupancyCost(from: CGPoint(x: 100, y: 20), to: CGPoint(x: 100, y: 60), occupied: [path])
        let tipCrossing = WorkflowConnectionRouter.occupancyCost(from: CGPoint(x: 215, y: 20), to: CGPoint(x: 215, y: 60), occupied: [path])
        // then
        #expect(opposite > same)
        #expect(tipCrossing > ordinaryCrossing)
        #expect(same.isFinite && same >= 0)
    }

    @MainActor @Test func givenEdgeBatch_whenReorderingPreviewingAndRetargeting_thenRoutesAreStableAndCacheInvalidatesCompletely() {
        // given
        let source = node("source", x: 60, y: 100)
        let upper = node("upper", x: 560, y: 100)
        let lower = node("lower", x: 560, y: 240)
        let nodes = [source, upper, lower]
        let first = WorkflowEdgeModel(raw: ["id": .string("a"), "source": .string("source"), "target": .string("upper")])
        let second = WorkflowEdgeModel(raw: ["id": .string("b"), "source": .string("source"), "target": .string("lower")])
        let cache = WorkflowRouteCache()
        // when
        let original = cache.routes(edges: [first, second], nodes: nodes)
        let reordered = cache.routes(edges: [second, first], nodes: nodes.reversed())
        _ = cache.preview(source: source, target: lower, endpoint: WorkflowCanvasGeometry.connectionInput(lower), nodes: nodes, edges: [second, first])
        // then
        #expect(original == reordered)
        #expect(cache.routes(edges: [first, second], nodes: nodes) == original)
        #expect(cache.computationCount == 2)
        // when
        let retargeted = WorkflowEdgeModel(raw: ["id": .string("b"), "source": .string("source"), "target": .string("upper")])
        let changed = cache.routes(edges: [first, retargeted], nodes: nodes)
        // then
        #expect(cache.computationCount == 4)
        #expect(changed["b"]?.last == WorkflowCanvasGeometry.connectionInput(upper))
        // when
        _ = cache.routes(edges: [first], nodes: nodes)
        _ = cache.routes(edges: [first, second], nodes: nodes)
        // then
        #expect(cache.computationCount == 7)
    }

    @MainActor @Test func givenShortAlignedGapAndUnrelatedEarlierEdge_whenBatchRouting_thenKeepsCompactStraightConnection() {
        // given
        let source = node("source", x: 190, y: 100)
        let target = node("target", x: 440, y: 100)
        let upper = node("upper", x: 190, y: 400)
        let upperTarget = node("upperTarget", x: 440, y: 400)
        let unrelated = WorkflowEdgeModel(raw: ["id": .string("a"), "source": .string("upper"), "target": .string("upperTarget")])
        let edge = WorkflowEdgeModel(raw: ["id": .string("b"), "source": .string("source"), "target": .string("target")])
        let duplicate = WorkflowEdgeModel(raw: ["id": .string("c"), "source": .string("source"), "target": .string("target")])
        // when
        let routes = WorkflowRouteCache().routes(edges: [unrelated, edge, duplicate], nodes: [source, target, upper, upperTarget])
        // then
        let direct = [WorkflowCanvasGeometry.connectionOutput(source), WorkflowCanvasGeometry.connectionInput(target)]
        #expect(routes["b"] == direct)
        #expect(routes["c"] == direct)
    }

    @MainActor @Test func givenEarlierRouteNearLaterDestination_whenBatchRouting_thenClearsLaterArrowhead() {
        // given
        let source = node("source", x: 20, y: 40)
        let target = node("target", x: 400, y: 300)
        let laterTarget = node("later", x: 250, y: 170)
        let laterSource = node("laterSource", x: 600, y: 170)
        let edges = [WorkflowEdgeModel(raw: ["id": .string("a"), "source": .string("source"), "target": .string("target")]),
                     WorkflowEdgeModel(raw: ["id": .string("z"), "source": .string("laterSource"), "target": .string("later")])]
        let tip = WorkflowCanvasGeometry.connectionInput(laterTarget)
        // when
        let routes = WorkflowRouteCache().routes(edges: edges, nodes: [source, target, laterTarget, laterSource])
        // then
        #expect(WorkflowConnectionRouter.clear(routes["a"]!, obstacles: [CGRect(x: tip.x - 9, y: tip.y - 7, width: 12, height: 14)]))
    }

    @MainActor @Test func givenMovedPrepareNode_whenBatchRouting_thenAvoidsWrappingBehindSourceWhenDestinationLoopIsAvailable() {
        // given
        let start = node("start", x: 40, y: 40, type: "start")
        let prepare = node("prepare", x: 170, y: 70)
        let plan = node("plan", x: 250, y: 170)
        let review = node("review", x: 500, y: 170)
        let baseline = node("baseline", x: 600, y: 310)
        let end = node("end", x: 900, y: 450, type: "end")
        let nodes = [start, prepare, plan, review, baseline, end]
        let pairs = [("a-start", start, prepare), ("b-prepare-plan", prepare, plan),
                     ("c-plan-review", plan, review), ("d-review-plan", review, plan),
                     ("e-review-baseline", review, baseline), ("f-baseline-end", baseline, end)]
        let edges = pairs.map { WorkflowEdgeModel(raw: ["id": .string($0.0), "source": .string($0.1.id), "target": .string($0.2.id)]) }
        // when
        let routes = WorkflowRouteCache().routes(edges: edges, nodes: nodes)
        let route = routes["b-prepare-plan"]!
        // then
        #expect(route.map(\.x).min()! >= prepare.position.x)
        #expect(route.first == WorkflowCanvasGeometry.connectionOutput(prepare))
        #expect(route.last == WorkflowCanvasGeometry.connectionInput(plan))
        #expect(WorkflowConnectionRouter.clear(route, obstacles: nodes.map { CGRect(origin: $0.position, size: WorkflowCanvasGeometry.size($0)) }))
    }

}
