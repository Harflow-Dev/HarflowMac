import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - WorkflowScreenLayoutTests + Builder

extension WorkflowScreenLayoutTests {
    @Test func givenBuilderTaskEmbeddedInEditor_whenRendered_thenItsTaskComposerHasNoDuplicateGlobalComposer() async throws {
        // given
        let vm = try QualifiedBuilderFixture.makeVM(name: "code-review")
        defer { vm.didDisappear() }
        vm.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string(String(repeating: "a", count: 32)),
            "kind": .string("builder"), "status": .string("running"), "builder_draft": .object(vm.definition),
            "activations": .array([.object(["role": .string("builder"), "tasks": .array([
                .object(["task_id": .string("builder-task")])])])])])
        (vm.useCase as? BuilderSessionUseCase)?.hostedRun = vm.selectedRun?.raw
        let fixture = RedesignHost(WorkflowView(vm, builderTaskView: { _, _ in
            AnyView(Text("Embedded builder Activity").accessibilityIdentifier("embedded-builder-activity"))
        }), size: CGSize(width: 1200, height: 800))
        defer { fixture.close() }
        // when
        await fixture.settle { fixture.element("embedded-builder-activity") != nil }
        // then
        #expect(!fixture.hasElement(containing: Self.composerLabel))
    }

    @Test(arguments: windowSizes, [ColorScheme.light, .dark])
    func givenBuilderRunAwaitingItsTask_whenHosted_thenNoComposerAndStartingLabelIsShown(size: CGSize, appearance: ColorScheme) async throws {
        // given
        let vm = try QualifiedBuilderFixture.makeVM(name: "code-review")
        defer { vm.didDisappear() }
        vm.selectedRun = QualifiedBuilderFixture.builderRun(vm, taskID: nil)
        #expect(vm.selectedRun?.builderTaskID == nil)
        let fixture = RedesignHost(WorkflowView(vm, builderTaskView: { _, _ in AnyView(Text("unexpected")) }).preferredColorScheme(appearance),
                                   size: size, appearance: appearance)
        defer { fixture.close() }
        // when
        await fixture.settle { fixture.element("Starting workflow builder…") != nil }
        // then
        #expect(fixture.element("Starting workflow builder…") != nil)
        #expect(fixture.element("unexpected") == nil)
        #expect(!fixture.hasElement(containing: Self.composerLabel))
    }

    @Test(arguments: windowSizes, [ColorScheme.light, .dark])
    func givenBuilderRunWithTaskAndInjectedView_whenHosted_thenInjectedViewIsShownWithoutOuterComposer(size: CGSize, appearance: ColorScheme) async throws {
        // given
        let vm = try QualifiedBuilderFixture.makeVM(name: "code-review")
        defer { vm.didDisappear() }
        vm.selectedRun = QualifiedBuilderFixture.builderRun(vm, taskID: "builder-task")
        #expect(vm.selectedRun?.builderTaskID == "builder-task")
        let fixture = RedesignHost(WorkflowView(vm, builderTaskView: { taskID, _ in
            AnyView(Text("Embedded \(taskID)").accessibilityIdentifier("embedded-builder-activity"))
        }).preferredColorScheme(appearance), size: size, appearance: appearance)
        defer { fixture.close() }
        // when
        await fixture.settle { fixture.element("embedded-builder-activity") != nil }
        // then
        #expect(fixture.element("embedded-builder-activity") != nil)
        #expect(fixture.element("Starting workflow builder…") == nil)
    }

    @Test(arguments: windowSizes, [ColorScheme.light, .dark])
    func givenQualifiedBuilderTask_whenHosted_thenActivityIsRightOfCanvasWithComposerAndInlineFacts(
        size: CGSize, appearance: ColorScheme
    ) async throws {
        // given
        let vm = try QualifiedBuilderFixture.makeVM(name: "code-review")
        defer { vm.didDisappear() }
        vm.selectedRun = QualifiedBuilderFixture.builderRun(vm, taskID: "builder-task")
        let task = PaneMocks.running(notices: ["Builder fixture notice"])
        let column = BuilderColumnProbe()
        let fixture = RedesignHost(NavigationSplitView {
            Text("Fixture sidebar").navigationSplitViewColumnWidth(240)
        } detail: {
            WorkflowView(vm, builderTaskView: { _, _ in
                AnyView(TaskDetailView(task, chrome: .builder, transcriptStyle: .transcript)
                    .background(BuilderColumnProbe.Representable(probe: column)))
            })
        }
        .environment(\.hfReduceMotionOverride, true)
        .preferredColorScheme(appearance), size: size, appearance: appearance)
        defer { fixture.close() }
        // when
        await fixture.settle { fixture.element("Task facts and reported result") != nil && column.view != nil }
        // then
        #expect(vm.builderRuntime == (vm.useCase as? BuilderSessionUseCase)?.runtimeToken)
        let canvas = try #require(fixture.element("workflow-builder-canvas"))
        let activity = try #require(fixture.element("workflow-builder-activity"))
        #expect(fixture.string(activity, "accessibilityLabel") == "Workflow builder activity")
        let workspace = try #require(fixture.element("workflow-builder-workspace"))
        let canvasFrame = try #require(fixture.frame(canvas))
        let workspaceFrame = try #require(fixture.frame(workspace))
        let columnView = try #require(column.view)
        let columnFrame = columnView.convert(columnView.bounds, to: nil)
        #expect(workspaceFrame.width < size.width, "Budget must use the detail viewport after the navigation sidebar")
        #expect(columnFrame.width > 0 && columnFrame.width <= 461)
        #expect(canvasFrame.minX >= workspaceFrame.minX - 1)
        #expect(abs(columnFrame.maxX - workspaceFrame.maxX) <= 1)
        #expect(abs(columnFrame.minX - canvasFrame.maxX - 1) <= 1)
        #expect(abs(columnFrame.minY - canvasFrame.minY) <= 1)
        #expect(abs(columnFrame.maxY - canvasFrame.maxY) <= 1)
        let composer = try #require(fixture.element("Queue a message…"))
        let composerFrame = try #require(fixture.frame(composer))
        #expect(composerFrame.minX >= columnFrame.minX - 1 && composerFrame.maxX <= columnFrame.maxX + 1)
        #expect(composerFrame.minY >= columnFrame.minY - 1 && composerFrame.maxY <= columnFrame.maxY + 1)
        let overflowing = fixture.descendants.filter { view in
            guard view !== columnView, !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 0 else { return false }
            let frame = view.convert(view.bounds, to: nil)
            return frame.minX >= columnFrame.minX - 1 && frame.minX < columnFrame.maxX - 1 && frame.maxX > columnFrame.maxX + 1
        }
        #expect(overflowing.isEmpty, "Views inside the builder column must not extend past it: \(overflowing.map { String(describing: type(of: $0)) })")
        #expect(fixture.element("Task facts and reported result") != nil)
        #expect(fixture.element("Show event details") == nil)
        #expect(fixture.element("Hide event details") == nil)
        #expect(fixture.element("Close right pane") == nil)
        #expect(!fixture.hasElement(containing: Self.composerLabel))
        let bar = try #require(fixture.element("Standalone nodes, outside the workflow path"))
        let barFrame = try #require(fixture.frame(bar))
        #expect(barFrame.minY >= canvasFrame.maxY - 1)
    }

    @Test(arguments: [CGFloat(460), 300], [ColorScheme.light, .dark])
    func givenBuilderSkeleton_whenLoadingInNarrowColumn_thenScrollDocumentFitsTheColumn(width: CGFloat, appearance: ColorScheme) async throws {
        // given
        let fixture = RedesignHost(TaskLoadingSkeleton(header: nil, chrome: .builder, style: .transcript)
            .environment(\.hfReduceMotionOverride, true)
            .preferredColorScheme(appearance), size: CGSize(width: width, height: 433), appearance: appearance)
        defer { fixture.close() }
        // when
        await fixture.settle { fixture.descendants.contains { ($0 as? NSScrollView)?.documentView != nil } }
        // then
        let scrolls = fixture.descendants.compactMap { $0 as? NSScrollView }.filter { $0.documentView != nil }
        #expect(!scrolls.isEmpty)
        for scroll in scrolls {
            let document = try #require(scroll.documentView)
            #expect(document.frame.width <= width + 1, "Skeleton document \(document.frame.width) must fit the \(width) pt column")
        }
        let overflowing = fixture.descendants.filter { view in
            !view.isHiddenOrHasHiddenAncestor && view.bounds.width > 0 && view.convert(view.bounds, to: nil).maxX > width + 1
        }
        #expect(overflowing.isEmpty, "\(overflowing.map { String(describing: type(of: $0)) })")
    }
}

// MARK: - BuilderColumnProbe

/// A test-side view filling the injected builder task view: the column's real layout frame, free of accessibility unions.
@MainActor private final class BuilderColumnProbe {
    var view: NSView?

    struct Representable: NSViewRepresentable {
        let probe: BuilderColumnProbe
        func makeNSView(context _: Context) -> NSView {
            let view = NSView()
            probe.view = view
            return view
        }

        func updateNSView(_: NSView, context _: Context) {}
    }
}
