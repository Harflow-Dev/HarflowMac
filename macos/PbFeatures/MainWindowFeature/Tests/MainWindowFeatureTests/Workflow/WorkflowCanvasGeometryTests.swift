import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbUI
import Testing

// MARK: - WorkflowCanvasGeometryTests

/// The Phase 3 token references keep the exact measured geometry contracts (SPEC §6.3/§8):
/// agent nodes 200 × 92, Start/End 72 × 72, parallel boundaries 110 × 72, 10 pt snapping and
/// the dot grid's density.
@MainActor
struct WorkflowCanvasGeometryTests {
    @Test func givenTokenizedNodeSizes_whenMeasured_thenContractsAreUnchanged() {
        // given / when / then
        #expect(PbRadius.Metrics.workflowNodeSize == CGSize(width: 200, height: 92))
        #expect(PbRadius.Metrics.workflowCompactNodeSize == CGSize(width: 72, height: 72))
        #expect(PbRadius.Metrics.workflowParallelBoundarySize == CGSize(width: 110, height: 72))
        #expect(WorkflowCanvasGeometry.size(WorkflowNodeModel(raw: ["type": .string("agent")])) == CGSize(width: 200, height: 92))
        #expect(WorkflowCanvasGeometry.size(WorkflowNodeModel(raw: ["type": .string("start")])) == CGSize(width: 72, height: 72))
        #expect(WorkflowCanvasGeometry.size(WorkflowNodeModel(raw: ["type": .string("end")])) == CGSize(width: 72, height: 72))
        #expect(WorkflowCanvasGeometry.size(WorkflowNodeModel(raw: ["type": .string("parallel_start")])) == CGSize(width: 110, height: 72))
    }

    @Test func givenTokenizedSnapGrid_whenSnapping_thenSpacingStaysTenPoints() {
        // given / when / then
        #expect(WorkflowCanvasGeometry.gridSpacing == 10)
        #expect(WorkflowCanvasGeometry.snapped(CGPoint(x: 117, y: -8)) == CGPoint(x: 120, y: 0))
        #expect(WorkflowCanvasGeometry.snapped(CGPoint(x: 213, y: 267)) == CGPoint(x: 210, y: 270))
    }

    @Test func givenTokenizedPorts_whenConnecting_thenEndpointsKeepTheirMeasuredOffsets() {
        // given
        let nodes = WorkflowJSON.nodes(WorkflowVM.starterDefinition())
        let source = nodes[0]
        let target = nodes[1]
        // when / then
        #expect(WorkflowCanvasGeometry.connectionOutput(source).x == WorkflowCanvasGeometry.output(source).x + 5.25)
        #expect(WorkflowCanvasGeometry.connectionInput(target).x == WorkflowCanvasGeometry.input(target).x - 5.25)
        #expect(WorkflowCanvasGeometry.connectionInput(target, highlighted: true).x == WorkflowCanvasGeometry.input(target).x - 6.75)
    }

    @Test func givenTokenizedDotGrid_whenProjected_thenDiameterAndDensityAreUnchanged() {
        // given / when / then
        #expect(abs(WorkflowCanvasGrid.diameter(scale: 1) - 1.7) < 0.001)
        #expect(WorkflowCanvasGrid.spacing(scale: 1) == 20)
        #expect(WorkflowCanvasGrid.spacing(scale: 0.5) == 40)
    }

    @Test func givenTokenizedInspectorWidths_whenClamped_thenSplitContractIsPreserved() {
        // given / when / then — the initial ideal width is the 288 visual adjustment; the
        // clamps and the canvas minimum are the unchanged native contracts.
        #expect(PbRadius.Metrics.workflowInspectorInitialWidth == 288)
        #expect(PbRadius.Metrics.workflowInspectorMinimumWidth == 220)
        #expect(PbRadius.Metrics.workflowInspectorMaximumWidth == 500)
        #expect(PbRadius.Metrics.workflowCanvasMinimumWidth == 400)
        #expect(PbRadius.Metrics.workflowRunPanelIdealWidth == 288)
    }
}
