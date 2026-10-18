import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

// MARK: - WorkflowCanvasNodeHostedTests

@MainActor @Suite(.serialized) struct WorkflowCanvasNodeHostedTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func givenVeryLongModel_whenActualCanvasNodeRenders_thenMetadataStaysOnOneLineWithoutCoveringPortsOrDetail(appearance: ColorScheme) async throws {
        // given
        let model = String(repeating: "provider/very-long-unlisted-model-name-", count: 15)
        let node = WorkflowNodeModel(raw: ["id": .string("model-node"), "title": .string("Long model step"),
                                          "type": .string("agent"), "role": .string("task"),
                                          "position": .object(["x": .number(50), "y": .number(50)]),
                                          "agent": .object(["backend": .string("codex"), "model": .string(model)])])
        let fixture = RedesignHost(
            WorkflowCanvas(nodes: [node], edges: [], selectedNodeID: nil, selectedEdgeID: nil, isEditable: false,
                           status: { _ in "completed" }, attempt: { _ in 0 }, onSelectNode: { _ in }, onSelectEdge: { _ in },
                           onMove: { _, _ in }, onConnect: { _ in }, onDrop: { _, _ in })
                .preferredColorScheme(appearance), size: CGSize(width: 400, height: 300)
        )
        defer { fixture.close() }
        await fixture.settle { fixture.element("Input to Long model step") != nil && fixture.element(model) != nil }

        // when
        let probe = try #require(fixture.descendants.compactMap { $0 as? WorkflowCanvasScrollProbe }.first)
        let logicalFrame = probe.convert(CGRect(origin: node.position, size: WorkflowCanvasGeometry.size(node)), to: nil)
        let metadata = try #require(fixture.element(model))
        let metadataFrame = try #require(fixture.frame(metadata))
        let input = try #require(fixture.element("Input to Long model step"))
        let output = try #require(fixture.element("Connect from Long model step"))
        let inputFrame = try #require(fixture.frame(input))
        let outputFrame = try #require(fixture.frame(output))
        let detail = try #require(fixture.element("Done"))
        let detailFrame = try #require(fixture.frame(detail))

        // then
        #expect(logicalFrame.size == CGSize(width: 200, height: 92))
        #expect(metadataFrame.width > 0 && metadataFrame.height <= PbRadius.Metrics.workflowNodeIconTileSize)
        #expect(logicalFrame.insetBy(dx: -1, dy: -1).contains(metadataFrame))
        #expect(metadataFrame.minX >= inputFrame.midX + WorkflowCanvasGeometry.portOuterRadius)
        #expect(metadataFrame.maxX <= outputFrame.midX - WorkflowCanvasGeometry.portOuterRadius)
        #expect(!metadataFrame.intersects(detailFrame), "Model metadata must not cover the retained node detail")
        #expect(fixture.string(metadata, "accessibilityHelp") == model, "The complete truncated model remains available in help")
    }

    @Test func givenLegacyCanvasChrome_whenHosted_thenBothNativeAxesBecomeOverlaySmallAndVisibleRectIsFresh() async throws {
        // given
        let nodes = [
            WorkflowNodeModel(raw: ["id": .string("start"), "type": .string("start"),
                                    "position": .object(["x": .number(50), "y": .number(50)])]),
            WorkflowNodeModel(raw: ["id": .string("end"), "type": .string("end"),
                                    "position": .object(["x": .number(1350), "y": .number(690)])])
        ]
        let fixture = RedesignHost(
            WorkflowCanvas(nodes: nodes, edges: [], selectedNodeID: nil, selectedEdgeID: nil, isEditable: false,
                           status: { _ in "completed" }, attempt: { _ in 0 }, onSelectNode: { _ in }, onSelectEdge: { _ in },
                           onMove: { _, _ in }, onConnect: { _ in }, onDrop: { _, _ in })
                .frame(width: 600, height: 420), size: CGSize(width: 600, height: 420)
        )
        defer { fixture.close() }
        await fixture.settle {
            guard let probe = fixture.descendants.compactMap({ $0 as? WorkflowCanvasScrollProbe }).first,
                  let scroll = probe.enclosingScrollView
            else { return false }
            return scroll.hasVerticalScroller && scroll.hasHorizontalScroller && probe.controller?.visibleRect != .zero
        }
        let probe = try #require(fixture.descendants.compactMap { $0 as? WorkflowCanvasScrollProbe }.first)
        let scroll = try #require(probe.enclosingScrollView)
        let controller = try #require(probe.controller)
        let document = try #require(scroll.documentView)
        let originalOrigin = scroll.contentView.bounds.origin
        // when — simulate AppKit applying the preferred legacy style, then notify the presentation
        // owner through the same public preference-change event it observes natively.
        scroll.scrollerStyle = .legacy
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        await waitUntil(timeout: 5) {
            fixture.host.layoutSubtreeIfNeeded()
            return scroll.scrollerStyle == .overlay
        }
        // then
        #expect(scroll.scrollerStyle == .overlay)
        #expect(scroll.hasVerticalScroller && scroll.hasHorizontalScroller)
        #expect(scroll.verticalScroller?.controlSize == .small)
        #expect(scroll.horizontalScroller?.controlSize == .small)
        #expect(scroll.documentView === document)
        #expect(scroll.contentView.bounds.origin == originalOrigin)
        let expectedVisible = probe.convert(scroll.contentView.bounds, from: scroll.contentView)
        #expect(controller.visibleRect == expectedVisible)
    }
}
