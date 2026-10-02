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

}
