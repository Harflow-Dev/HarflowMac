import AppKit
import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowCanvasScrollingTests

@MainActor
@Suite struct WorkflowCanvasScrollingTests {
    @Test func givenPointerAtViewportEdges_whenComputingScrollStep_thenMovesBothAxesAndStaysBounded() {
        // given
        let viewport = CGRect(x: 300, y: 200, width: 800, height: 500)
        // when / then
        #expect(WorkflowCanvasScrolling.step(pointer: CGPoint(x: 700, y: 450), viewport: viewport) == .zero)
        #expect(WorkflowCanvasScrolling.step(pointer: CGPoint(x: 1100, y: 700), viewport: viewport) == CGSize(width: 12, height: 12))
        #expect(WorkflowCanvasScrolling.step(pointer: CGPoint(x: 250, y: 150), viewport: viewport) == CGSize(width: -12, height: -12))
        let near = WorkflowCanvasScrolling.step(pointer: CGPoint(x: 1080, y: 450), viewport: viewport)
        #expect(near.width > 0 && near.width < 12)
        #expect(near.height == 0)
    }

    @Test func givenDocumentBounds_whenScrollingPastEdges_thenOnlyActualAppliedDeltaIsAvailable() {
        // given
        let document = CGRect(x: 0, y: 0, width: 2000, height: 1500)
        let viewport = CGSize(width: 800, height: 500)
        // when / then
        #expect(WorkflowCanvasScrolling.clampedOrigin(CGPoint(x: -12, y: -8), viewport: viewport, document: document) == .zero)
        #expect(WorkflowCanvasScrolling.clampedOrigin(CGPoint(x: 1212, y: 1020), viewport: viewport, document: document) == CGPoint(x: 1200, y: 1000))
        #expect(WorkflowCanvasZoom.logical(CGSize(width: 6, height: 12), scale: 0.5) == CGSize(width: 12, height: 24))
    }

    @Test func givenWideScrolledCanvas_whenDrawingGrid_thenVisitsViewportOnlyAndKeepsLogicalOrigin() {
        // given
        let visible = CGRect(x: 6000, y: 400, width: 800, height: 500)
        // when
        let grid = WorkflowCanvasScrolling.visibleGrid(visible, scale: 2, content: CGSize(width: 20000, height: 2000))
        // then
        #expect(grid == CGRect(x: 2990, y: 190, width: 420, height: 270))
        #expect(grid.width * grid.height < 120000)
    }

    @Test func givenCachedRoutes_whenScrollingOrChangingOnlyTitles_thenReusesRouteButGeometryChangesRecompute() {
        // given
        let cache = WorkflowRouteCache()
        var nodes = WorkflowJSON.nodes(WorkflowVM.starterDefinition())
        let source = nodes[0]
        let target = nodes[1]
        let endpoint = WorkflowCanvasGeometry.connectionInput(target)
        // when
        let original = cache.route(id: "edge", source: source, target: target, endpoint: endpoint, nodes: nodes)
        nodes[1].raw["title"] = .string("Renamed")
        let renamed = cache.route(id: "edge", source: source, target: target, endpoint: endpoint, nodes: nodes)
        // then
        #expect(renamed == original)
        #expect(cache.computationCount == 1)
        // when
        nodes[1].raw["position"] = .object(["x": .number(450), "y": .number(250)])
        _ = cache.route(id: "edge", source: source, target: nodes[1], endpoint: WorkflowCanvasGeometry.connectionInput(nodes[1]), nodes: nodes)
        // then
        #expect(cache.computationCount == 2)
        cache.retain(ids: [])
        _ = cache.route(id: "edge", source: source, target: nodes[1], endpoint: WorkflowCanvasGeometry.connectionInput(nodes[1]), nodes: nodes)
        #expect(cache.computationCount == 3)
    }

    @Test func givenActiveNodeDrag_whenStopping_thenStopsAndClearsTransientState() {
        // given
        let controller = WorkflowCanvasScrollController()
        controller.updateNode(id: "node", point: CGPoint(x: 60, y: 100), scale: 1, onMove: { _, _ in })
        // when
        controller.stop()
        // then
        #expect(!controller.isDragging)
        #expect(controller.connectionDrag == nil)
    }

    @Test func givenNonFlippedScrollDocument_whenConvertingViewport_thenUsesTopLeftCanvasCoordinatesAndAppliedLogicalDelta() {
        // given
        let controller = WorkflowCanvasScrollController()
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 2000, height: 1000))
        let probe = WorkflowCanvasScrollProbe(controller: controller)
        probe.frame = document.bounds
        document.addSubview(probe)
        scroll.documentView = document
        controller.attach(probe)
        let before = controller.visibleRect
        // when
        scroll.contentView.scroll(to: CGPoint(x: 100, y: 100))
        controller.refreshVisibleRect()
        // then
        #expect(probe.isFlipped)
        #expect(before.minY == 700)
        #expect(controller.visibleRect.minX == 100)
        #expect(controller.visibleRect.minY == 600)
        #expect(WorkflowCanvasScrolling.logicalScrollDelta(before: before, after: controller.visibleRect, scale: 0.5)
            == CGSize(width: 200, height: -200))
        controller.detach()
    }

}
