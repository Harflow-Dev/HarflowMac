import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - WorkflowRunSidebarHostedTests selected-node pane

extension WorkflowRunSidebarHostedTests {
    @Test(arguments: [CGSize(width: 1000, height: 620), CGSize(width: 1440, height: 900)], [ColorScheme.light, .dark])
    func givenWorkerNodeWithGoalAndRepo_whenSelected_thenHeadBadgeGoalAndCaptionRenderInThePane(size: CGSize, appearance: ColorScheme) async throws {
        // given
        let vm = WorkflowPreview.make(run: true)
        defer { vm.didDisappear() }
        let nodeID = try #require(vm.nodes.first { $0.type == "agent" }?.id)
        var raw = try #require(vm.selectedRun?.raw)
        raw["repo_path"] = .string("/tmp/OrbitDesk")
        raw["goal"] = .string("Verify the release.")
        raw["activations"] = .array([workerActivation(nodeID: nodeID, taskID: "task-0")])
        vm.selectedRun = WorkflowRunModel(raw: raw)
        WorkflowPreview.synchronizeRun(vm)
        let fixture = RedesignHost(WorkflowView(vm).preferredColorScheme(appearance), size: size)
        defer { fixture.close() }

        // when
        vm.selectedNodeID = nodeID
        await fixture.settle { paneElement("workflow-selected-status", in: fixture) != nil }
        await fixture.settle { paneContains("Verify the release.", in: fixture) }

        // then
        #expect(paneElement("workflow-selected-status", in: fixture) != nil)
        #expect(paneContains("OrbitDesk", in: fixture), "The caption names the run's repository")
        #expect(paneContains("Verify the release.", in: fixture), "The goal text itself is shown")
        #expect(vm.runSidebar.header.kind == .worker)
    }

    @Test(arguments: [CGSize(width: 1000, height: 620), CGSize(width: 1440, height: 900)])
    func givenRunOptingIntoCallerApprovals_whenWorkerNodeIsSelected_thenColumnCarriesGateAndFeedKeepsItsFloor(size: CGSize) async throws {
        // given: the approval panel builds its own repository from the global environment, so no card can be injected here;
        // this asserts the gate, the column's task and the layout floor with the region mounted.
        let vm = WorkflowPreview.make(run: true)
        defer { vm.didDisappear() }
        let nodeID = try #require(vm.nodes.first { $0.type == "agent" }?.id)
        var raw = try #require(vm.selectedRun?.raw)
        raw["caller_approvals"] = .bool(true)
        raw["goal"] = .string("Verify the release.")
        raw["activations"] = .array([workerActivation(nodeID: nodeID, taskID: "task-0")])
        vm.selectedRun = WorkflowRunModel(raw: raw)
        WorkflowPreview.synchronizeRun(vm)
        let parallelTests = ParallelVMTests()
        let harness = parallelTests.makeSUT()
        harness.tasksBox.value["task-0"] = parallelTests.task(id: "task-0", status: "running")
        harness.itemsBox.value["task-0"] = [PreviewFixtures.textItem("Node activity")]
        harness.availabilityBox.value["task-0"] = .available
        vm.parallel = harness.sut
        let fixture = RedesignHost(WorkflowView(vm), size: size)
        defer { fixture.close() }

        // when
        vm.selectedNodeID = nodeID
        await vm.sidebarTask?.value
        harness.tasksSubject.send(Array(harness.tasksBox.value.values))
        await fixture.settle { vm.selectedActivity?.columns.first?.inspectorApproval != nil && paneFeed(in: fixture) != nil }

        // then
        let column = try #require(vm.selectedActivity?.columns.first)
        #expect(column.inspectorApproval == WorkflowSelectedApprovalGate(mounts: true, polls: true))
        #expect(column.task.taskID == "task-0")
        #expect(paneElement("parallel-column-composer", in: fixture) != nil, "The composer stays below the approval region")
        let reportedChrome = WorkflowSelectedPaneSizing.columnChrome(pieces: [], itemCount: 1)
        #expect(reportedChrome > 0, "A single-conversation column still contributes chrome (padding) to the pane reserve")
        let feed = try #require(paneFeed(in: fixture))
        #expect(feed.bounds.height >= WorkflowSelectedPaneSizing.transcriptFloor)
    }

    @Test(arguments: [CGSize(width: 1000, height: 620), CGSize(width: 1440, height: 900)], [ColorScheme.light, .dark])
    func givenOnDemandCallsWithDistinctTranscripts_whenRowIsPressed_thenDisplayedTranscriptChanges(size: CGSize, appearance: ColorScheme) async throws {
        // given
        let vm = WorkflowOnDemandPreview.make(run: true)
        defer { vm.didDisappear() }
        var raw = try #require(vm.selectedRun?.raw)
        raw["activations"] = .array(WorkflowJSON.objects(raw["activations"]).map { activation in
            guard let id = activation["id"]?.stringValue, id.hasPrefix("specialist-") else { return .object(activation) }
            var copy = activation
            copy["tasks"] = .array([.object(["task_id": .string("task-" + id), "status": .string("completed")])])
            return .object(copy)
        })
        vm.selectedRun = WorkflowRunModel(raw: raw)
        WorkflowPreview.synchronizeRun(vm)
        let parallelTests = ParallelVMTests()
        let harness = parallelTests.makeSUT()
        for (id, text) in [("task-specialist-1", "Transcript of call one"), ("task-specialist-2", "Transcript of call two")] {
            harness.tasksBox.value[id] = parallelTests.task(id: id, status: "completed")
            harness.itemsBox.value[id] = [PreviewFixtures.textItem(text)]
            harness.availabilityBox.value[id] = .available
        }
        vm.parallel = harness.sut
        let fixture = RedesignHost(WorkflowView(vm).preferredColorScheme(appearance), size: size)
        defer { fixture.close() }
        await vm.sidebarTask?.value
        harness.tasksSubject.send(Array(harness.tasksBox.value.values))
        await fixture.settle {
            paneContains("Call 1", in: fixture) && paneContains("Transcript of call two", in: fixture)
                && vm.selectedActivity?.columns.first?.task.taskID == "task-specialist-2"
        }
        #expect(paneContains("Transcript of call two", in: fixture), "The latest call's transcript text is rendered")
        #expect(!paneContains("Transcript of call one", in: fixture))
        #expect(paneContains("On demand", in: fixture))
        #expect(paneContains("CALLS", in: fixture))
        #expect(vm.runSidebar.activationID == "specialist-2")

        // when
        let row = try #require(paneElements(in: fixture).first { fixture.string($0, "accessibilityLabel")?.contains("Call 1") == true })
        #expect(fixture.press(row))
        harness.tasksSubject.send(Array(harness.tasksBox.value.values))
        await fixture.settle {
            vm.runSidebar.activationID == "specialist-1" && paneContains("Transcript of call one", in: fixture)
                && !paneContains("Transcript of call two", in: fixture)
        }

        // then
        #expect(vm.selectedActivationID == "specialist-1")
        #expect(vm.runSidebar.caption?.hasPrefix("Call 1") == true)
        #expect(vm.selectedActivity?.columns.first?.task.taskID == "task-specialist-1", "The shown transcript follows the pressed call")
        #expect(paneContains("Transcript of call one", in: fixture), "The pressed call's transcript text is rendered")
        #expect(!paneContains("Transcript of call two", in: fixture), "The previous call's transcript text is gone")
    }

    // MARK: Pane-scoped lookups

    private func workerActivation(nodeID: String, taskID: String) -> JSONValue {
        .object(["id": .string("attempt-0"), "role": .string("node"), "node_id": .string(nodeID), "status": .string("running"),
                 "tasks": .array([.object(["task_id": .string(taskID), "status": .string("running")])])])
    }

    /// The inspector pane of the run's split view, the subtree of `workflow-selected-sidebar`.
    private func pane(in fixture: RedesignHost) -> NSView? {
        fixture.descendants.compactMap { $0 as? NSSplitView }.last { $0.isVertical }?.arrangedSubviews.last
    }

    private func allPaneViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allPaneViews) }

    private func paneElements(in fixture: RedesignHost) -> [NSObject] {
        guard fixture.element("workflow-selected-sidebar") != nil, let pane = pane(in: fixture) else { return [] }
        return allPaneViews(pane).flatMap { fixture.elements(in: $0) }
    }

    private func paneElement(_ label: String, in fixture: RedesignHost) -> NSObject? {
        paneElements(in: fixture).first { fixture.matches($0, label) }
    }

    private func paneContains(_ text: String, in fixture: RedesignHost) -> Bool {
        paneElements(in: fixture).contains { element in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains {
                fixture.string(element, $0)?.contains(text) == true
            }
        }
    }

    private func paneFeed(in fixture: RedesignHost) -> ActivityFeedNativeScrollView? {
        pane(in: fixture).flatMap { allPaneViews($0).compactMap { $0 as? ActivityFeedNativeScrollView }.first }
    }
}
