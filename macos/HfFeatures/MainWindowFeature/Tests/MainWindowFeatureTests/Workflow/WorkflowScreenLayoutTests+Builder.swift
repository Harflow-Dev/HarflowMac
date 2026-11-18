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
        let vm = try builderVM()
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

    private func builderRun(_ vm: WorkflowVM, taskID: String?) -> WorkflowRunModel {
        var raw: [String: JSONValue] = ["workflow_run_id": .string(String(repeating: "b", count: 32)),
            "kind": .string("builder"), "status": .string("running"), "builder_draft": .object(vm.definition)]
        if let taskID {
            raw["activations"] = .array([.object(["role": .string("builder"), "tasks": .array([.object(["task_id": .string(taskID)])])])])
        }
        (vm.useCase as? BuilderSessionUseCase)?.hostedRun = raw
        return WorkflowRunModel(raw: raw)
    }

    private func builderVM() throws -> WorkflowVM {
        let useCase = BuilderSessionUseCase(status: "running")
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let vm = WorkflowBuilderSessionTests().vm(store: store, useCase: useCase)
        vm.newWorkflow()
        vm.name = "code-review"
        vm.loadedName = vm.name
        vm.savedDefinition = vm.definition
        vm.selectedNodeID = nil
        vm.builderRuntime = try useCase.activityRuntime()
        return vm
    }

    @Test(arguments: windowSizes, [ColorScheme.light, .dark])
    func givenBuilderRunAwaitingItsTask_whenHosted_thenNoComposerAndStartingLabelIsShown(size: CGSize, appearance: ColorScheme) async throws {
        // given
        let vm = try builderVM()
        defer { vm.didDisappear() }
        vm.selectedRun = builderRun(vm, taskID: nil)
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
        let vm = try builderVM()
        defer { vm.didDisappear() }
        vm.selectedRun = builderRun(vm, taskID: "builder-task")
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
        let vm = try builderVM()
        defer { vm.didDisappear() }
        vm.selectedRun = builderRun(vm, taskID: "builder-task")
        let task = PaneMocks.running(notices: ["Builder fixture notice"])
        let fixture = RedesignHost(NavigationSplitView {
            Text("Fixture sidebar").navigationSplitViewColumnWidth(240)
        } detail: {
            WorkflowView(vm, builderTaskView: { _, _ in
                AnyView(TaskDetailView(task, chrome: .builder, transcriptStyle: .transcript))
            })
        }.preferredColorScheme(appearance), size: size, appearance: appearance)
        defer { fixture.close() }
        // when
        await fixture.settle { fixture.element("Queue a message…") != nil }
        // then
        #expect(vm.builderRuntime == (vm.useCase as? BuilderSessionUseCase)?.runtimeToken)
        let canvas = try #require(fixture.element("workflow-builder-canvas"))
        let activity = try #require(fixture.element("workflow-builder-activity"))
        let workspace = try #require(fixture.element("workflow-builder-workspace"))
        let canvasFrame = try #require(fixture.frame(canvas))
        let activityFrame = try #require(fixture.frame(activity))
        let workspaceFrame = try #require(fixture.frame(workspace))
        #expect(workspaceFrame.width < size.width, "Budget must use the detail viewport after the navigation sidebar")
        #expect(activityFrame.width > 0 && activityFrame.width <= 461)
        #expect(canvasFrame.minX >= workspaceFrame.minX - 1)
        #expect(abs(activityFrame.maxX - workspaceFrame.maxX) <= 1)
        #expect(abs(activityFrame.minX - canvasFrame.maxX - 1) <= 1)
        #expect(abs(activityFrame.minY - canvasFrame.minY) <= 1)
        #expect(abs(activityFrame.maxY - canvasFrame.maxY) <= 1)
        let composer = try #require(fixture.element("Queue a message…"))
        let composerFrame = try #require(fixture.frame(composer))
        #expect(composerFrame.minX >= activityFrame.minX - 1 && composerFrame.maxX <= activityFrame.maxX + 1)
        #expect(composerFrame.minY >= activityFrame.minY - 1 && composerFrame.maxY <= activityFrame.maxY + 1)
        #expect(fixture.element("Task facts and reported result") != nil)
        #expect(fixture.element("Show event details") == nil)
        #expect(fixture.element("Hide event details") == nil)
        #expect(fixture.element("Close right pane") == nil)
        #expect(!fixture.hasElement(containing: Self.composerLabel))
        let bar = try #require(fixture.element("Standalone nodes, outside the workflow path"))
        let barFrame = try #require(fixture.frame(bar))
        #expect(barFrame.minY >= canvasFrame.maxY - 1)
    }

}
