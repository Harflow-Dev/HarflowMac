import AppKit
import HfCommon
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - WorkInteractionCaptureTests

/// Opt-in native production-view fixtures; no engine or user state is opened.
@MainActor @Suite(.serialized)
struct WorkInteractionCaptureTests {
    @Test func givenInteractionSurfaces_whenCaptured_thenNativeFixturesRenderInBothAppearances() async throws {
        guard let path = ProcessInfo.processInfo.environment["HARFLOW_WORK_CAPTURE_DIR"], !path.isEmpty else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let notices = ["Approaching the turn limit.", "Provider diagnostic retained."]
        let combined = TaskDetailViewModelMock.continuity(notices: notices)
        combined.title = "Continuity verification fixture"
        let none = TaskDetailViewModelMock()
        let noticeOnly = TaskDetailViewModelMock.continuity(status: "completed", notices: notices)
        let continuityOnly = TaskDetailViewModelMock.continuity()
        let run = WorkflowPreview.make(run: true)
        let editor = WorkflowPreview.make()
        let fixtures: [(String, AnyView, CGSize)] = [
            ("header-combined", AnyView(TaskDetailView(combined)), CGSize(width: 1000, height: 620)),
            ("header-combined-narrow", AnyView(TaskDetailView(combined)), CGSize(width: 520, height: 620)),
            ("header-combined-embedded", AnyView(TaskDetailView(combined, isEmbedded: true)), CGSize(width: 288, height: 620)),
            ("header-no-supplement", AnyView(TaskDetailView(none)), CGSize(width: 1000, height: 620)),
            ("header-notices", AnyView(TaskDetailView(noticeOnly)), CGSize(width: 1000, height: 620)),
            ("header-continuity", AnyView(TaskDetailView(continuityOnly)), CGSize(width: 1000, height: 620)),
            ("workflow-run", AnyView(WorkflowView(run)), CGSize(width: 1200, height: 800)),
            ("workflow-editor", AnyView(WorkflowView(editor)), CGSize(width: 1200, height: 800))
        ]
        for (name, view, size) in fixtures {
            for dark in [false, true] {
                let data = try await capture(view, size: size, dark: dark)
                try data.write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                #expect(data.count > 10_000)
            }
        }
        run.didDisappear()
        editor.didDisappear()
    }

    @Test func givenNodeAndParallelActivity_whenCaptured_thenEachSurfaceShowsItsOwnComposer() async throws {
        guard let path = ProcessInfo.processInfo.environment["HARFLOW_WORK_CAPTURE_DIR"], !path.isEmpty else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var columns = ParallelViewModelMock.sampleColumns()
        for index in columns.indices {
            columns[index].onSubmitMessage = { _, _ in true }
            columns[index].onCancelMessage = { _ in }
        }
        let parallel = ParallelViewModelMock(columns: columns)
        let orchestrator = await makeOrchestratorActivity()
        let native = await makeNativeActivity()
        defer { orchestrator.didDisappear(); native.didDisappear() }
        let fixtures: [(String, AnyView, CGSize)] = [
            ("parallel-composers", AnyView(ParallelView(parallel, initiallyPrepared: true)), CGSize(width: 1300, height: 800)),
            ("orchestrator-activity-composer", AnyView(WorkflowView(orchestrator)), CGSize(width: 1300, height: 800)),
            ("native-activity-composer", AnyView(WorkflowSelectedSidebar(viewModel: native)), CGSize(width: 288, height: 700))
        ]
        for (name, view, size) in fixtures {
            for dark in [false, true] {
                let data = try await capture(view, size: size, dark: dark)
                try data.write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                #expect(data.count > 10_000)
            }
        }
    }

    private func makeOrchestratorActivity() async -> WorkflowVM {
        let vm = WorkflowOnDemandPreview.make(run: true, orchestrator: true)
        vm.selectedNodeID = nil
        await vm.sidebarTask?.value
        let tests = ParallelVMTests()
        let harness = tests.makeSUT()
        let task = tests.task(id: "decision-task", status: "running")
        harness.tasksBox.value[task.taskID] = task
        harness.itemsBox.value[task.taskID] = [PreviewFixtures.textItem("Orchestrator decision activity")]
        harness.availabilityBox.value[task.taskID] = .available
        vm.parallel = harness.sut
        vm.selectStandalone(WorkflowStandalone.orchestratorID)
        await vm.sidebarTask?.value
        harness.tasksSubject.send([task])
        return vm
    }

    private func makeNativeActivity() async -> WorkflowVM {
        let vm = WorkflowPreview.make(run: true)
        var raw = vm.selectedRun?.raw ?? [:]
        raw["activations"] = .array([.object([
            "id": .string("native-execution"), "node_id": .string("review"), "role": .string("node"),
            "status": .string("running"), "tasks": .array([.object([
                "task_id": .string("native-task"), "status": .string("running"), "execution_kind": .string("native_subagent")])])])])
        vm.selectedRun = WorkflowRunModel(raw: raw)
        await vm.sidebarTask?.value
        vm.nativeActivityTask?.cancel()
        vm.runSidebar = WorkflowRunSidebarPresentation(
            node: ["id": .string("review"), "title": .string("Review")], activationID: "native-execution", taskIDs: ["native-task"])
        vm.nativeActivity = WorkflowNativeActivityModel(executionID: "native-execution", title: "Review", status: "running", limited: false,
            items: [PreviewFixtures.textItem("Native review activity")], loaded: true)
        return vm
    }

    private func capture(_ view: AnyView, size: CGSize, dark: Bool) async throws -> Data {
        let controller = NSHostingController(rootView: view
            .environment(\.hfReduceMotionOverride, true)
            .preferredColorScheme(dark ? .dark : .light))
        controller.sceneBridgingOptions = .all
        let host = controller.view
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.contentView = nil; window.close() }
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        for _ in 0 ..< 6 { await DisplayFrames.waitForPresentedFrame() }
        guard let representation = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CaptureError.noBitmap
        }
        host.cacheDisplay(in: host.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw CaptureError.noBitmap
        }
        return data
    }

    private enum CaptureError: Error { case noBitmap }
}
