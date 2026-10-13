import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import SwiftUI
import Testing

// MARK: - WindowedWorkflowLayoutTests

@MainActor @Suite(.serialized) struct WindowedWorkflowLayoutTests {
    @Test(arguments: [CGSize(width: 1440, height: 900), CGSize(width: 1000, height: 620)], [false, true])
    func givenWorkflow_whenWindowedWithUnifiedChrome_thenHeadersRemainInsideContent(_ size: CGSize, _ isBuilder: Bool) async throws {
        // given
        let sidebar = SidebarViewModelMock()
        sidebar.savedWorkflows = [WorkflowRecord(raw: ["name": .string("Android Feature Implementation")])]
        let workflow = WorkflowPreview.make()
        workflow.name = "Android Feature Implementation"
        workflow.loadedName = workflow.name
        if isBuilder {
            workflow.selectedRun = WorkflowRunModel(raw: [
                "workflow_run_id": .string("windowed-builder"), "kind": .string("builder"),
                "name": .string(workflow.name), "status": .string("running"),
                "builder_draft": .object(workflow.definition),
                "activations": .array([.object(["role": .string("builder"),
                    "tasks": .array([.object(["task_id": .string("builder-task")])])])])
            ])
        }
        let task = TaskDetailViewModelMock()
        let fixture = RedesignHost(NavigationSplitView {
            SidebarView(sidebar).navigationSplitViewColumnWidth(min: 240, ideal: 272, max: 340)
        } detail: {
            WorkflowView(workflow, builderTaskView: { _, _ in AnyView(TaskDetailView(task, isEmbedded: true)) })
        }
            .frame(minWidth: 1000, minHeight: 620)
            .toolbar(removing: .title), size: size)
        fixture.window.styleMask.insert([.closable, .miniaturizable, .resizable, .fullSizeContentView])
        fixture.window.titleVisibility = .hidden
        fixture.window.titlebarAppearsTransparent = true
        fixture.window.toolbar = NSToolbar(identifier: "windowed-workflow")
        fixture.window.toolbarStyle = .unified
        defer { workflow.didDisappear(); fixture.close() }
        // when
        for target in [size, CGSize(width: size.width == 1000 ? 1440 : 1000, height: size.height == 620 ? 900 : 620)] {
            let previousHeader = fixture.element("New session").flatMap { fixture.frame($0) }
            fixture.window.setContentSize(target)
            await fixture.settle { fixture.element("New session") != nil && fixture.element("Android Feature Implementation") != nil
                && fixture.host.frame.width == target.width
                && fixture.element("New session").flatMap { fixture.frame($0) } != previousHeader
                && (!isBuilder || hasActivity(in: fixture))
            }
            workflow.didDisappear()
            // then
            try assertHeaders(in: fixture, taskTitleLabel: isBuilder ? task.title : nil)
        }
    }

    private func hasActivity(in fixture: RedesignHost) -> Bool {
        fixture.descendants
.compactMap { $0 as? ActivityFeedNativeTableView }
            .contains { $0.bounds.width > 0 && $0.bounds.height > 0 }
    }

    private func assertHeaders(in fixture: RedesignHost, taskTitleLabel: String?) throws {
        let nativeChromeHeight = fixture.window.frame.height - fixture.window.contentLayoutRect.height
        #expect(fixture.host.fittingSize.height <= 620 + nativeChromeHeight + 1,
                "Workflow must not inflate navigation minimum height through wrapped headers or native panes")
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
        let outline = try #require(fixture.descendants.compactMap { $0 as? NSOutlineView }.first)
        let navigation = try #require(fixture.descendants.compactMap { $0 as? NSSplitView }.first {
            $0.isVertical && $0.arrangedSubviews.count == 2 && outline.isDescendant(of: $0.arrangedSubviews[0])
        })
        let detailPane = navigation.arrangedSubviews[1]
        let detailBounds = detailPane.convert(detailPane.bounds, to: nil)
        let detailTitle = try #require(titles.compactMap { fixture.frame($0) }.first { $0.minX >= detailBounds.minX })
        #expect(detailTitle.maxY <= fixture.window.contentLayoutRect.maxY,
                "Workflow title must fit below the native titlebar: \(detailTitle), content=\(fixture.window.contentLayoutRect)")
        if let taskTitleLabel {
            let table = try #require(fixture.descendants.compactMap { $0 as? ActivityFeedNativeTableView }.first)
            let activityViewport = try #require(table.enclosingScrollView)
            let activityBounds = activityViewport.convert(activityViewport.bounds, to: nil)
            #expect(activityBounds.minX >= detailBounds.minX && activityBounds.maxX <= detailBounds.maxX,
                    "Real native activity viewport must remain within the navigation detail pane")
            let taskTitle = try #require(fixture.element(taskTitleLabel))
            let taskBounds = try #require(fixture.frame(taskTitle))
            #expect(taskBounds.minX >= detailBounds.minX && taskBounds.maxX <= detailBounds.maxX,
                    "Real embedded task header must stay inside detail pane: \(taskBounds), detail=\(detailBounds)")
            #expect(taskBounds.maxY <= detailTitle.minY,
                    "Real embedded task header must remain below the workflow header")
        }
    }
}
