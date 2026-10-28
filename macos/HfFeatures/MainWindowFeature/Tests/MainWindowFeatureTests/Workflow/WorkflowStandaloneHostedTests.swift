import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - WorkflowStandaloneHostedTests

@MainActor @Suite(.serialized) struct WorkflowStandaloneHostedTests {
    @Test(arguments: [ColorScheme.light, .dark], [true, false])
    func givenDecisionTask_whenStandaloneIsSelected_thenCardAndInspectorShowActualActivity(appearance: ColorScheme, running: Bool) async throws {
        // given
        let vm = WorkflowOnDemandPreview.make(run: true, orchestrator: true, status: running ? "running" : "succeeded")
        let tests = ParallelVMTests()
        let harness = tests.makeSUT()
        let task = tests.task(id: "decision-task", status: running ? "running" : "completed")
        harness.tasksBox.value[task.taskID] = task
        harness.itemsBox.value[task.taskID] = [PreviewFixtures.textItem("Orchestrator decision activity")]
        harness.availabilityBox.value[task.taskID] = .available
        vm.parallel = harness.sut
        vm.selectedNodeID = nil
        await vm.sidebarTask?.value
        let fixture = RedesignHost(WorkflowView(vm).preferredColorScheme(appearance).environment(\.hfReduceMotionOverride, true),
                                   size: CGSize(width: 1440, height: 900), appearance: appearance)
        defer { vm.didDisappear(); fixture.close() }

        // when
        vm.selectStandalone(WorkflowStandalone.orchestratorID)
        await vm.sidebarTask?.value
        harness.tasksSubject.send([task])
        await fixture.settle {
            fixture.element("Orchestrator decision activity") != nil && fixture.element("1 activity item") != nil
        }

        // then
        #expect(fixture.element(running ? "Orchestrator, running" : "Orchestrator, pending") != nil)
        #expect(fixture.element("Orchestrator decision activity") != nil)
        #expect(fixture.element("1 activity item") != nil)
        #expect(fixture.element("Open task") != nil)
        #expect(vm.selectedActivity?.leasedMemberCount == 1)
        if let path = ProcessInfo.processInfo.environment["HARFLOW_STANDALONE_CAPTURE_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // The running outline intentionally animates; capture after the activity itself has settled.
            await fixture.settle { fixture.hasRenderedInk }
            let mode = running ? "running" : "idle"
            let scheme = appearance == .light ? "light" : "dark"
            try fixture.capturePNG(to: directory.appendingPathComponent("orchestrator-\(mode)-\(scheme).png"))
        }
    }
}
