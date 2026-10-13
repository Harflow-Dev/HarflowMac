import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import SwiftUI
import Testing

// MARK: - WindowedWorkflowLayoutTests

@MainActor @Suite(.serialized) struct WindowedWorkflowLayoutTests {
    @Test(arguments: [CGSize(width: 1440, height: 900), CGSize(width: 1000, height: 620)])
    func givenIdleWorkflow_whenWindowedWithUnifiedChrome_thenHeadersRemainBelowWindowControls(_ size: CGSize) async throws {
        // given
        let sidebar = SidebarViewModelMock()
        sidebar.savedWorkflows = [WorkflowRecord(raw: ["name": .string("Android Feature Implementation")])]
        let workflow = WorkflowPreview.make()
        workflow.name = "Android Feature Implementation"
        workflow.loadedName = workflow.name
        let fixture = RedesignHost(NavigationSplitView {
            SidebarView(sidebar).navigationSplitViewColumnWidth(min: 240, ideal: 272, max: 340)
        } detail: { WorkflowView(workflow) }
            .frame(minWidth: 1000, minHeight: 620)
            .toolbar(removing: .title), size: size)
        fixture.window.styleMask.insert([.closable, .miniaturizable, .resizable, .fullSizeContentView])
        fixture.window.titleVisibility = .hidden
        fixture.window.titlebarAppearsTransparent = true
        fixture.window.toolbar = NSToolbar(identifier: "windowed-workflow")
        fixture.window.toolbarStyle = .unified
        defer { workflow.didDisappear(); fixture.close() }
        // when
            await fixture.settle { fixture.element("New session") != nil && fixture.element("Android Feature Implementation") != nil }
            workflow.didDisappear()
            // then
            let close = try #require(fixture.window.standardWindowButton(.closeButton))
            let controls = close.convert(close.bounds, to: nil)
            let newSession = try #require(fixture.element("New session"))
            let newSessionBounds = try #require(fixture.frame(newSession))
            #expect(newSessionBounds.maxY <= fixture.window.contentLayoutRect.maxY,
                    "New session must fit below the native titlebar: \(newSessionBounds), content=\(fixture.window.contentLayoutRect)")
            #expect(newSessionBounds.maxY < controls.minY,
                    "New session must stay below traffic lights: \(newSessionBounds), controls=\(controls)")
            let titles = fixture.descendants.flatMap { fixture.elements(in: $0) }.filter {
                fixture.matches($0, "Android Feature Implementation")
            }
            let detailTitle = try #require(titles.compactMap { fixture.frame($0) }.first { $0.minX > 340 })
            #expect(detailTitle.maxY <= fixture.window.contentLayoutRect.maxY,
                    "Workflow title must fit below the native titlebar: \(detailTitle), content=\(fixture.window.contentLayoutRect)")
    }
}
