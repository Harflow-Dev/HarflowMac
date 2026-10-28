import AppKit
import Combine
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import SwiftUI
import Testing

// MARK: - WorkflowRunSidebarHostedTests

@MainActor @Suite(.serialized) struct WorkflowRunSidebarHostedTests {
    @Test func givenTwoActivityNodes_whenSwitchingAwayAndBackAtSameWidth_thenSelectedFeedMountIsRecreated() async throws {
        let vm = WorkflowPreview.make(run: true)
        defer { vm.didDisappear() }
        let nodeIDs = vm.nodes.filter { $0.type == "agent" }.prefix(2).map(\.id)
        let firstNode = try #require(nodeIDs.first)
        let secondNode = try #require(nodeIDs.dropFirst().first)
        var raw = try #require(vm.selectedRun?.raw)
        raw["activations"] = .array(nodeIDs.enumerated().map { index, nodeID in
            .object(["id": .string("attempt-\(index)"), "role": .string("node"), "node_id": .string(nodeID),
                     "status": .string("completed"), "tasks": .array([.object(["task_id": .string("task-\(index)")])])])
        })
        vm.selectedRun = WorkflowRunModel(raw: raw)
        WorkflowPreview.synchronizeRun(vm)
        vm.selectedNodeID = firstNode
        let parallelTests = ParallelVMTests()
        let parallelHarness = parallelTests.makeSUT()
        parallelHarness.tasksBox.value["task-0"] = parallelTests.task(id: "task-0", status: "completed")
        parallelHarness.tasksBox.value["task-1"] = parallelTests.task(id: "task-1", status: "completed")
        parallelHarness.itemsBox.value["task-0"] = [PreviewFixtures.textItem("First node activity")]
        parallelHarness.itemsBox.value["task-1"] = [PreviewFixtures.textItem("Second node activity")]
        parallelHarness.availabilityBox.value["task-0"] = .available
        parallelHarness.availabilityBox.value["task-1"] = .available
        vm.parallel = parallelHarness.sut
        let fixture = RedesignHost(WorkflowView(vm), size: CGSize(width: 900, height: 700))
        defer { fixture.close() }
        parallelHarness.tasksSubject.send(Array(parallelHarness.tasksBox.value.values))
        await fixture.settle { fixture.element("workflow-selected-sidebar") != nil }
        parallelHarness.tasksSubject.send(Array(parallelHarness.tasksBox.value.values))
        await fixture.settle { vm.selectedActivity?.leasedMemberCount == 1 }
        #expect(vm.selectedActivity?.leasedMemberCount == 1)
        let firstScroll = try #require(activityScroll(in: fixture))

        vm.selectedNodeID = secondNode
        await vm.sidebarTask?.value
        parallelHarness.tasksSubject.send(Array(parallelHarness.tasksBox.value.values))
        await fixture.settle {
            fixture.element("workflow-selected-sidebar") != nil
                && activityScroll(in: fixture) != nil
                && activityScroll(in: fixture) !== firstScroll
        }
        let secondScroll = try #require(activityScroll(in: fixture))
        await fixture.settle { vm.selectedActivity?.leasedMemberCount == 1 }
        #expect(vm.selectedActivity?.leasedMemberCount == 1)

        vm.selectedNodeID = firstNode
        await vm.sidebarTask?.value
        parallelHarness.tasksSubject.send(Array(parallelHarness.tasksBox.value.values))
        await fixture.settle {
            fixture.element("workflow-selected-sidebar") != nil
                && activityScroll(in: fixture) !== secondScroll
        }
        let restoredScroll = try #require(activityScroll(in: fixture))
        await fixture.settle { vm.selectedActivity?.leasedMemberCount == 1 }
        #expect(vm.selectedActivity?.leasedMemberCount == 1)

        #expect(restoredScroll !== secondScroll)
        #expect(restoredScroll !== firstScroll, "A same-width owner swap must recreate the feed mount so leases reacquire")
    }

    @Test(arguments: [220.0, 288.0], [ColorScheme.light, .dark])
    func givenPopulatedChildRun_whenSidePanelScrolls_thenDisclosuresHistoryAndRoutesRemainReachable(width: Double, appearance: ColorScheme) async throws {
        // given
        let (vm, routing, raw, nodeID) = try makeRun()
        let fixture = RedesignHost(WorkflowView(vm).preferredColorScheme(appearance), size: CGSize(width: 900, height: 700))
        defer { vm.didDisappear(); fixture.close() }
        await fixture.settle { fixture.element("Open owning orchestrator") != nil }
        #expect(vm.runSidebar.isDefault)
        #expect(fixture.element("workflow-selected-sidebar") == nil)
        vm.didDisappear()
        vm.selectedRun = WorkflowRunModel(raw: raw)
        vm.selectedNodeID = nil
        let split = try #require(fixture.descendants.compactMap { $0 as? NSSplitView }.first { $0.isVertical })
        split.setPosition(split.bounds.width - width - split.dividerThickness, ofDividerAt: 0)
        await fixture.settle { abs((split.arrangedSubviews.last?.bounds.width ?? 0) - width) < 1 }
        let pane = try #require(split.arrangedSubviews.last)
        let scroll = try #require(allViews(pane).compactMap { $0 as? NSScrollView }.first)

        // when / then: the real retained side panel, not a checklist-only facsimile.
        #expect(abs(pane.bounds.width - width) < 1)
        #expect(fixture.element("Child workflow · Plan and checklist belong to this run") != nil)
        let owner = try await reveal("Open owning orchestrator", using: scroll, fixture: fixture)
        #expect(fixture.press(owner))
        verify(routing).openWorkflowRun(id: .value("preview-owner-run")).called(1)
        let child = try await reveal("Select child workflow Review, run 1, completed", using: scroll, fixture: fixture)
        #expect(fixture.press(child))
        verify(routing).openWorkflowRun(id: .value("preview-child-run")).called(1)
        try await openDisclosures(using: scroll, fixture: fixture)
        #expect(fixture.element("Assignment for this child") != nil)
        #expect(fixture.element("Technical plan") != nil)
        // when / then: root runs retain the same request, with their original disclosure label.
        try await checkRootRequest(vm: vm, raw: raw, scroll: scroll, fixture: fixture)

        // Hiding and restoring the selected sidebar keeps the default inspector's
        // disclosure state and reading position. This observes the visible default
        // surface after the selected sidebar is dismissed.
        let retainedOrigin = scroll.contentView.bounds.origin
        vm.selectedNodeID = nodeID
        await fixture.settle { fixture.element("workflow-selected-sidebar") != nil }
        #expect(fixture.element("workflow-selected-sidebar") != nil)
        vm.selectedNodeID = nil
        await fixture.settle { fixture.element("workflow-selected-sidebar") == nil && fixture.element("Original request") != nil }
        #expect(fixture.element("workflow-selected-sidebar") == nil)
        #expect(fixture.element("Original request") != nil)
        #expect(abs(scroll.contentView.bounds.origin.y - retainedOrigin.y) < 2)
        #expect(containsText("Prepare the release:", in: fixture))
    }

    private func reveal(_ label: String, using scroll: NSScrollView, fixture: RedesignHost) async throws -> NSObject {
        let document = try #require(scroll.documentView)
        var previousFrame = CGRect.zero
        await fixture.settle {
            guard let element = scopedElement(label, document: document, fixture: fixture),
                  let frame = fixture.frame(element) else { return false }
            document.scrollToVisible(document.convert(frame, from: nil))
            scroll.reflectScrolledClipView(scroll.contentView)
            let visible = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
            let stable = frame == previousFrame
            previousFrame = frame
            return stable && visible.insetBy(dx: -1, dy: -1).contains(frame)
        }
        let element = try #require(scopedElement(label, document: document, fixture: fixture))
        let visible = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
        let reached = try #require(fixture.frame(element))
        #expect(reached.width > 0 && reached.height > 0)
        #expect(visible.insetBy(dx: -1, dy: -1).contains(reached),
                "Side-panel \(label) [\(fixture.string(element, "accessibilityRole") ?? "unknown")] must remain inside \(visible); actual \(reached)")
        return element
    }

    private func makeRun() throws -> (WorkflowVM, MockWorkflowRouting, [String: JSONValue], String) {
        let preview = WorkflowPreview.makePopulatedChildRun()
        defer { preview.didDisappear() }
        var raw = try #require(preview.selectedRun?.raw)
        let nodeID = try #require(preview.selectedNodeID)
        raw["activations"] = .array([
            .object(["id": .string("older-attempt"), "role": .string("node"), "node_id": .string(nodeID),
                     "status": .string("completed"), "attempt_in_visit": .number(1),
                     "assignment_prompt": .string("Retained assignment from the earlier activation."),
                     "invocation": .object(["child_workflow_run_id": .string("preview-child-run"),
                                             "workflow_name": .string("Review"), "stage": .string("completed")])]),
            .object(["id": .string("newer-attempt"), "role": .string("node"), "node_id": .string(nodeID),
                     "status": .string("completed"), "attempt_in_visit": .number(2)])
        ])
        let routing = MockWorkflowRouting()
        given(routing).openWorkflowRun(id: .any).willReturn()
        let useCase = MockWorkflowUseCase()
        given(useCase).agentUsageSnapshot.willReturn(.init())
        given(useCase).agentUsagePublisher().willReturn(Just(.init()).eraseToAnyPublisher())
        given(useCase).backendIDs.willReturn(["codex", "claude"])
        given(useCase).modelOptions(backend: .any).willReturn([])
        given(useCase).refreshTasks().willReturn()
        given(useCase).command(.any, options: .any, positionals: .any).willReturn(raw)
        let vm = WorkflowVM(useCase: useCase, routing: routing, parallel: ParallelVMTests().makeSUT().sut,
                            draftStore: WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                                    visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        vm.definition = preview.definition
        vm.selectedRun = WorkflowRunModel(raw: raw)
        vm.selectedNodeID = nil
        return (vm, routing, raw, nodeID)
    }

    private func openDisclosures(using scroll: NSScrollView, fixture: RedesignHost) async throws {
        for label in ["Assignment for this child", "Technical plan"] {
            let disclosure = try await reveal(label, using: scroll, fixture: fixture)
            #expect(fixture.press(disclosure))
            let sourceText = label == "Technical plan"
                ? "Bump the version constant."
                : "Prepare the release: update the version, run the suite, and draft the changelog."
            await fixture.settle { containsText(sourceText, in: fixture) }
            #expect(containsText(sourceText, in: fixture), "The disclosure must expose its actual retained source text")
        }
    }

    private func checkRootRequest(vm: WorkflowVM, raw: [String: JSONValue], scroll: NSScrollView, fixture: RedesignHost) async throws {
        var root = raw
        root["parent_workflow_run_id"] = nil
        vm.selectedRun = WorkflowRunModel(raw: root)
        await fixture.settle { fixture.element("Original request") != nil }
        #expect(fixture.element("Assignment for this child") == nil)
        let request = try await reveal("Original request", using: scroll, fixture: fixture)
        // Disclosure state survives the child's label changing to its root label.
        if !containsText("Prepare the release:", in: fixture) { #expect(fixture.press(request)) }
        await fixture.settle { containsText("Prepare the release:", in: fixture) }
        #expect(containsText("Prepare the release:", in: fixture))
    }

    private func scopedElement(_ label: String, document: NSView, fixture: RedesignHost) -> NSObject? {
        allViews(document).flatMap { fixture.elements(in: $0) }.first { fixture.matches($0, label) }
    }

    private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

    private func containsText(_ text: String, in fixture: RedesignHost) -> Bool {
        fixture.descendants.flatMap { fixture.elements(in: $0) }.contains { element in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains {
                fixture.string(element, $0)?.contains(text) == true
            }
        }
    }

    private func activityScroll(in fixture: RedesignHost) -> NSScrollView? {
        guard let sidebar = fixture.element("workflow-selected-sidebar"),
              let sidebarFrame = fixture.frame(sidebar) else { return nil }
        return fixture.descendants.compactMap { $0 as? NSScrollView }.first { scroll in
            guard scroll.hasVerticalScroller, !scroll.hasHorizontalScroller, scroll.documentView is NSTableView else { return false }
            let frame = scroll.convert(scroll.bounds, to: fixture.host)
            return frame.intersects(sidebarFrame)
        }
    }
}
