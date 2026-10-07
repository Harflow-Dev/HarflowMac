import AppKit
@testable import MainWindowFeature
import MonitorCore
import Observation
import PbTestUtilities
import SwiftUI
import Testing

// MARK: - WorkflowCanvasViewportTests

@MainActor @Suite(.serialized) struct WorkflowCanvasViewportTests {
    @Test(arguments: ["Graph", "Parallel"])
    func givenLargeRun_whenSidebarAndWindowChange_thenPanesRemainInsideDetail(mode: String) async throws {
        // given
        _ = NSApplication.shared
        let layout = CanvasViewportState()
        let nodes = fixtureNodes()
        let vm = WorkflowPreview.make(run: true)
        var definition = vm.definition
        definition["nodes"] = .array(nodes.map { .object($0.raw) })
        vm.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("canvas-fixture"), "name": .string("Canvas fixture"),
                                             "status": .string("running"), "definition": .object(definition)])
        let domain = "polybridge-canvas-fixture-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.set(mode, forKey: "workflowViewMode")
        defer { defaults.removePersistentDomain(forName: domain) }
        let host = NSHostingView(rootView: NavigationSplitView(columnVisibility: Binding(
            get: { layout.visibility }, set: { layout.visibility = $0 }
        )) {
            SidebarView(SidebarViewModelMock())
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { layout.sidebar = $0 }
                .navigationSplitViewColumnWidth(min: 240, ideal: 272, max: 340)
        } detail: {
            WorkflowView(vm)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { layout.detail = $0 }
        }
.frame(minWidth: 1000, minHeight: 620)
.defaultAppStorage(defaults))
        let size = CGSize(width: 1512, height: 950)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        let cases: [(CGSize, NavigationSplitViewVisibility)] = [
            (size, .all), (CGSize(width: 1000, height: 620), .all), (size, .detailOnly), (size, .all)
        ]
        for (size, visibility) in cases {
            // when
            layout.visibility = visibility
            window.setContentSize(size)
            await waitUntil {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
                let boundary = visibility == .detailOnly ? 0 : layout.sidebar.maxX
                return layout.detail.width > 600 && abs(layout.detail.minX - boundary) < 1
                    && abs(layout.detail.maxX - host.bounds.maxX) < 1
            }
            let split = try #require(descendants(of: host).compactMap { $0 as? NSSplitView }.last { $0.isVertical })
            let paneViewport = host.convert(split.bounds, from: split)
            // then
            #expect(abs(layout.detail.maxX - host.bounds.maxX) < 1)
            #expect(abs(paneViewport.minX - layout.detail.minX) < 1)
            #expect(abs(paneViewport.maxX - layout.detail.maxX) < 1)
            #expect(paneViewport.height > 100)
            #expect(split.arrangedSubviews.count == 2)
            for pane in split.arrangedSubviews {
                #expect(split.bounds.contains(pane.frame))
                #expect(pane.frame.width > 100)
            }
            guard mode == "Graph" else { continue }
            try assertStartVisible(in: host, nodes: nodes, detail: layout.detail, visibility: visibility)
        }
    }

    private func fixtureNodes() -> [WorkflowNodeModel] {
        WorkflowJSON.nodes(["nodes": .array([
            .object(["id": .string("start"), "type": .string("start"), "position": .object(["x": .number(50), "y": .number(50)])]),
            .object(["id": .string("prepare"), "type": .string("agent"), "position": .object(["x": .number(180), "y": .number(40)])]),
            .object(["id": .string("end"), "type": .string("end"), "position": .object(["x": .number(1350), "y": .number(690)])])
        ])])
    }

    private func assertStartVisible(in host: NSView, nodes: [WorkflowNodeModel], detail: CGRect,
                                    visibility: NavigationSplitViewVisibility) throws {
        let probe = try #require(descendants(of: host).compactMap { $0 as? WorkflowCanvasScrollProbe }.first)
        let scroll = try #require(probe.enclosingScrollView)
        let document = try #require(scroll.documentView)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: document.isFlipped ? 0 : document.bounds.height - scroll.contentView.bounds.height))
        let viewport = host.convert(scroll.contentView.bounds, from: scroll.contentView)
        let start = try #require(nodes.first { $0.id == "start" })
        let startFrame = host.convert(CGRect(origin: start.position, size: WorkflowCanvasGeometry.size(start)), from: probe)
        // then
        #expect(visibility == .detailOnly ? detail.minX < 1 : detail.minX > 100)
        #expect(abs(viewport.minX - detail.minX) < 1)
        #expect(viewport.contains(startFrame), "Start must be fully visible at logical (50, 50), beside the sidebar")
        #expect(viewport.maxX <= host.bounds.maxX)
        #expect(abs(probe.convert(scroll.contentView.bounds, from: scroll.contentView).minX) < 1)
        #expect(abs(probe.convert(scroll.contentView.bounds, from: scroll.contentView).minY) < 1)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

// MARK: - CanvasViewportState

@MainActor @Observable private final class CanvasViewportState {
    var visibility = NavigationSplitViewVisibility.all
    var sidebar = CGRect.zero
    var detail = CGRect.zero
}
