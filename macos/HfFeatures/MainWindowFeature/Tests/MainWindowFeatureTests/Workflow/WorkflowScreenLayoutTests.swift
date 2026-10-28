import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import Observation
import SwiftUI
import Testing

// MARK: - WorkflowScreenLayoutTests

@MainActor @Suite(.serialized) struct WorkflowScreenLayoutTests {
    @Test func givenBuilderTaskEmbeddedInEditor_whenRendered_thenItsTaskComposerHasNoDuplicateGlobalComposer() async throws {
        // given
        let vm = WorkflowPreview.make()
        defer { vm.didDisappear() }
        vm.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string(String(repeating: "a", count: 32)),
            "kind": .string("builder"), "status": .string("running"), "builder_draft": .object(vm.definition),
            "activations": .array([.object(["role": .string("builder"), "tasks": .array([
                .object(["task_id": .string("builder-task")])])])])])
        let fixture = RedesignHost(WorkflowView(vm, builderTaskView: { _, _ in
            AnyView(Text("Embedded builder Activity").accessibilityIdentifier("embedded-builder-activity"))
        }), size: CGSize(width: 1200, height: 800))
        defer { fixture.close() }
        // when
        await fixture.settle { fixture.element("embedded-builder-activity") != nil }
        // then
        #expect(fixture.element("workflow-builder-message-composer") == nil)
    }

    @Test
    func givenLongLoadedRun_whenContentChangesAndWindowResizes_thenNavigationMinimumStaysStable() async throws {
        // given
        _ = NSApplication.shared
        let vm = WorkflowPreview.make(run: true)
        var raw = try #require(vm.selectedRun?.raw)
        raw["status"] = .string("cancelled")
        raw["decisions"] = .array([.object(["reason": .string(String(repeating: "A recent workflow decision explains the next branch. ", count: 12))])])
        raw["pending"] = .array((0 ..< 3).map { _ in .object(["decision_attempts": .number(1)]) })
        raw["prompt"] = .string(String(repeating: "A very long original request with specifications.\n", count: 20))
        raw["tasks"] = longChecklist()
        raw["technical_plan"] = .string("The final technical plan remains reachable below the checklist.")
        raw["activations"] = .array((0 ..< 6).map { .object([
            "invocation": .object(["child_workflow_run_id": .string("child-\($0)"), "workflow_name": .string("Child workflow \($0)")])
        ]) })
        vm.selectedRun = WorkflowRunModel(raw: raw)
        #expect(vm.selectedRun?.childRunIDs.count == 6)
        vm.selectedNodeID = try #require(vm.nodes.first?.id)
        #expect(vm.selectedNode != nil)
        let fixture = RedesignHost(NavigationSplitView {
            Text("Sidebar top").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } detail: { WorkflowView(vm) }.frame(minWidth: 1000, minHeight: 620), size: CGSize(width: 2210, height: 864))
        let host = fixture.host
        defer { fixture.close() }
        // when
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        // The native fixture owns updates; prevent the preview's automatic polling replacing them.
        vm.didDisappear()
        vm.selectedRun = WorkflowRunModel(raw: raw)
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        // then
        #expect(host.fittingSize.height == 620)
        #expect(host.intrinsicContentSize.height == 620)
        let compactPanes = try #require(descendants(of: host).compactMap { $0 as? NSSplitView }.last { $0.isVertical })
        for status in ["cancelled", "running"] {
            raw["status"] = .string(status)
            vm.selectedRun = WorkflowRunModel(raw: raw)
            await waitUntil {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
                return compactPanes.bounds.height > host.bounds.height - 200
            }
            #expect(vm.selectedRun?.status == status)
            try assertLoadedViewport(compactPanes, in: fixture)
        }
        // when
        raw["status"] = .string("needs_attention")
        raw["pending"] = .array((0 ..< 80).map { _ in .object(["decision_attempts": .number(1)]) })
        vm.selectedRun = WorkflowRunModel(raw: raw)
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        // then
        #expect(host.fittingSize.height == 620)
        #expect(host.intrinsicContentSize.height == 620)
        // when
        fixture.window.setContentSize(CGSize(width: 1000, height: 620))
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        // then
        #expect(host.fittingSize.height == 620)
        #expect(host.intrinsicContentSize.height == 620)
        #expect(fixture.window.contentLayoutRect.height == 620)
        let expand = try #require(fixture.element("Expand summary"))
        #expect(fixture.press(expand))
        await fixture.settle { fixture.element("Collapse summary") != nil }
        try assertAccessiblePanes(in: host)
    }

    private func assertLoadedViewport(_ split: NSSplitView, in fixture: RedesignHost) throws {
        let panes = split.convert(split.bounds, to: nil)
        let content = fixture.window.contentLayoutRect
        #expect(fixture.element("workflow-builder-message-composer") == nil,
                "A workflow run must not show the create/edit builder composer below its canvas")
        #expect(panes.height > fixture.host.bounds.height - 200,
                "Compact status must retain the full run viewport without a global composer")
        #expect(abs(panes.minY - content.minY - 36) < 1,
                "Only the intrinsic collapsed summary should separate the panes from the bottom edge")
        #expect(panes.minY >= content.minY - 1 && panes.maxY <= content.maxY + 1)
    }

    private func assertAccessiblePanes(in host: NSView) throws {
        let split = try #require(descendants(of: host).compactMap { $0 as? NSSplitView }.last { $0.isVertical })
        let paneBounds = host.convert(split.bounds, from: split)
        #expect(paneBounds.minY >= -1)
        #expect(paneBounds.maxY <= host.bounds.maxY + 1)
        #expect(split.arrangedSubviews.allSatisfy { $0.bounds.height > 0 })
        let inspectorPane = try #require(split.arrangedSubviews.last)
        let inspector = try #require(descendants(of: inspectorPane).compactMap { $0 as? NSScrollView }.first)
        let diagnostics = try #require(descendants(of: host).compactMap { $0 as? NSScrollView }.first { !$0.isDescendant(of: split) })
        for scroll in [diagnostics, inspector] {
            #expect((scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height + 20)
            let document = try #require(scroll.documentView)
            let bottom = max(0, document.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: document.isFlipped ? bottom : 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            let visible = scroll.documentVisibleRect
            #expect(document.isFlipped ? abs(visible.maxY - document.bounds.maxY) < 2 : abs(visible.minY) < 2)
        }
    }

    private func longChecklist() -> JSONValue {
        .array((0 ..< 19).map { .object([
            "id": .string("task-\($0)"), "title": .string("Long checklist task \($0)"),
            "description": .string(String(repeating: "detail\n", count: 3))
        ]) })
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @Test(arguments: ["failure", "preparing", "loaded"], [
        CGSize(width: 1440, height: 1440), CGSize(width: 2210, height: 864), CGSize(width: 1000, height: 620)
    ])
    func givenWorkflowState_whenLaidOutAndThenLoaded_thenHeaderStaysAtTop(_ kind: String, _ size: CGSize) async throws {
        // given
        _ = NSApplication.shared
        let state = ScreenLayoutState(kind: kind)
        let host = NSHostingView(rootView: ScreenLayoutFixture(state: state))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        defer { window.contentView = nil; window.close() }
        // when
        await waitUntil { host.layoutSubtreeIfNeeded(); return state.probe?.bounds.height == 90 }
        let probe = try #require(state.probe)
        let before = host.convert(probe.bounds, from: probe)
        let top = host.isFlipped ? before.minY : host.bounds.height - before.maxY
        // then
        #expect(abs(top) < 1, "Header was centered at \(top) instead of pinned to the top")
        state.kind = "loaded"
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        let after = host.convert(probe.bounds, from: probe)
        #expect(abs(after.minY - before.minY) < 1)
        #expect(abs(after.height - before.height) < 1)
    }
}

// MARK: - ScreenLayoutState

@MainActor @Observable private final class ScreenLayoutState {
    var kind: String
    var probe: NSView?
    init(kind: String) { self.kind = kind }
}

// MARK: - ScreenLayoutFixture

private struct ScreenLayoutFixture: View {
    let state: ScreenLayoutState
    var body: some View {
        WorkflowScreenLayout {
            Text("Workflow header / Graph / Parallel")
.frame(maxWidth: .infinity)
.frame(height: 90)
                .background(HeaderGeometryProbe { state.probe = $0 })
        } content: {
            switch state.kind {
            case "failure": ContentUnavailableView("Workflow could not be loaded", systemImage: "exclamationmark.triangle")
            case "preparing": WorkflowLoadingView(isRun: true)
            default: Color.clear
            }
        }
    }
}

// MARK: - HeaderGeometryProbe

private struct HeaderGeometryProbe: NSViewRepresentable {
    let didCreate: (NSView) -> Void
    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        didCreate(view)
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
}
