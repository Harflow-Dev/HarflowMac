import AppKit
import Combine
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
        #expect(feed.bounds.height >= WorkflowSelectedPaneSizing.transcriptFloor - 0.5,
                "The activity feed keeps its minimum viewport height")
    }

    @Test(arguments: [CGSize(width: 1000, height: 620), CGSize(width: 1440, height: 900)], [ColorScheme.light, .dark])
    func givenOnDemandCallsWithDistinctTranscripts_whenRowIsPressed_thenDisplayedTranscriptChanges(size: CGSize, appearance: ColorScheme) async throws {
        // given
        let previousActivationPolicy = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(previousActivationPolicy) }
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
        let initialTasks = ["task-specialist-1", "task-specialist-2"].map {
            parallelTests.task(id: $0, status: "completed")
        }
        let taskUpdates = CurrentValueSubject<[TaskInfo], Never>(initialTasks)
        let harness = parallelTests.makeSUT(tasksPublisher: taskUpdates.eraseToAnyPublisher())
        for (id, text) in [("task-specialist-1", "Transcript of call one"), ("task-specialist-2", "Transcript of call two")] {
            harness.tasksBox.value[id] = try #require(initialTasks.first { $0.taskID == id })
            harness.itemsBox.value[id] = [PreviewFixtures.textItem(text)]
            harness.availabilityBox.value[id] = .available
        }
        vm.parallel = harness.sut
        let fixture = RedesignHost(WorkflowView(vm).preferredColorScheme(appearance), size: size)
        defer { fixture.close() }
        await vm.sidebarTask?.value
        taskUpdates.send(Array(harness.tasksBox.value.values))
        func selectionDiagnostic() -> String {
            let activity = vm.selectedActivity
            let columns = activity?.columns.map { "\($0.id):resident=\($0.isResident)" }.joined(separator: ",") ?? "none"
            let identity = activity.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
            let width = paneFeed(in: fixture)?.owner?.currentWidth ?? 0
            return "selectedConversationID=\(activity?.selectedConversationID ?? "nil"), columns=[\(columns)], "
                + "selectedActivity=\(identity), taskIDs=\(vm.runSidebar.taskIDs), "
                + "sourceUpdates=\(harness.sut.sourceUpdateCount), viewportWidth=\(width), appearance=\(appearance), size=\(size)"
        }
        await fixture.settle {
            guard let feed = paneFeed(in: fixture),
                  let column = vm.selectedActivity?.columns.first,
                  column.task.taskID == "task-specialist-2" else { return false }
            return paneContains("Call 1", in: fixture)
                && feedContainsTaskRow("task-specialist-2", feed: feed)
        }
        let initialFeed = try #require(paneFeed(in: fixture), Comment(rawValue: selectionDiagnostic()))
        try await revealTranscriptRow(taskID: "task-specialist-2", text: "Transcript of call two", feed: initialFeed, fixture: fixture)
        #expect(paneContains("Transcript of call two", in: fixture), "The latest call's transcript text is rendered")
        #expect(!paneContains("Transcript of call one", in: fixture))
        #expect(paneContains("On demand", in: fixture))
        #expect(paneContains("CALLS", in: fixture))
        #expect(vm.runSidebar.activationID == "specialist-2")

        try await exercisePointerAndKeyboardCallSwitch(vm: vm, harness: harness, taskUpdates: taskUpdates, fixture: fixture,
                                                       diagnostic: selectionDiagnostic)

        // then
        #expect(vm.selectedActivationID == "specialist-2")
        #expect(vm.selectedActivity?.columns.first?.task.taskID == "task-specialist-2")
        #expect(paneContains("Transcript of call two", in: fixture), "The keyboard-selected call's transcript is rendered")
        #expect(!paneContains("Transcript of call one", in: fixture))
    }

    // MARK: Pane-scoped lookups

    func workerActivation(nodeID: String, taskID: String) -> JSONValue {
        .object(["id": .string("attempt-0"), "role": .string("node"), "node_id": .string(nodeID), "status": .string("running"),
                 "tasks": .array([.object(["task_id": .string(taskID), "status": .string("running")])])])
    }

    /// The inspector pane of the run's split view, the subtree of `workflow-selected-sidebar`.
    func pane(in fixture: RedesignHost) -> NSView? {
        fixture.descendants.compactMap { $0 as? NSSplitView }.last { $0.isVertical }?.arrangedSubviews.last
    }

    func allPaneViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allPaneViews) }

    func paneElements(in fixture: RedesignHost) -> [NSObject] {
        guard fixture.element("workflow-selected-sidebar") != nil, let pane = pane(in: fixture) else { return [] }
        return allPaneViews(pane).flatMap { fixture.elements(in: $0) }
    }

    func paneElement(_ label: String, in fixture: RedesignHost) -> NSObject? {
        paneElements(in: fixture).first { fixture.matches($0, label) }
    }

    func paneContains(_ text: String, in fixture: RedesignHost) -> Bool {
        paneElements(in: fixture).contains { element in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains {
                fixture.string(element, $0)?.contains(text) == true
            }
        }
    }

    func paneFeed(in fixture: RedesignHost) -> ActivityFeedNativeScrollView? {
        pane(in: fixture).flatMap { allPaneViews($0).compactMap { $0 as? ActivityFeedNativeScrollView }.first }
    }

    func revealTranscriptRow(taskID: String, text: String, feed: ActivityFeedNativeScrollView,
                             fixture: RedesignHost) async throws {
        let table = try #require(feed.documentView as? ActivityFeedNativeTableView)
        let index = try #require(table.owner?.entries.firstIndex { entry in
            if case .row(let row) = entry { return row.row.taskID == taskID }
            return false
        }, "The selected table model contains the exact task transcript row")
        table.scrollRowToVisible(index)
        feed.reflectScrolledClipView(feed.contentView)
        await fixture.settle { paneContains(text, in: fixture) }
        #expect(paneContains(text, in: fixture), "Scrolling the selected activity row realizes its transcript")
    }

    func feedContainsTaskRow(_ taskID: String, feed: ActivityFeedNativeScrollView) -> Bool {
        guard let table = feed.documentView as? ActivityFeedNativeTableView else { return false }
        return table.owner?.entries.contains { entry in
            if case .row(let row) = entry { return row.row.taskID == taskID }
            return false
        } == true
    }

    func remountedCallButton(_ identifier: String, in feed: ActivityFeedNativeScrollView) -> NSButton? {
        let activationID = identifier.replacingOccurrences(of: "workflow-call-selector-", with: "")
        guard let table = feed.documentView as? ActivityFeedNativeTableView,
              let index = table.owner?.entries.firstIndex(where: { entry in
                  if case .supplementary(let row) = entry {
                      return row.kind == .callSelector && row.id.hasSuffix("-" + activationID)
                  }
                  return false
              }),
              let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ActivityFeedNativeCell else {
            return nil
        }
        return allPaneViews(cell)
.compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == identifier }
    }

    func visibleCallButton(_ identifier: String, in feed: ActivityFeedNativeScrollView,
                           fixture: RedesignHost) async throws -> NSButton {
        var result: NSButton?
        await fixture.settle {
            guard feed.window === fixture.window,
                  let button = remountedCallButton(identifier, in: feed),
                  let frame = fixture.frame(button) else { return false }
            result = button
            return feed.contentView.convert(feed.contentView.bounds, to: nil).contains(frame)
        }
        return try #require(result, Comment(rawValue: callButtonDiagnostic(identifier, in: feed, fixture: fixture)))
    }

    func revealCallButtonForInput(_ identifier: String, in feed: ActivityFeedNativeScrollView,
                                  fixture: RedesignHost) async throws -> NSButton {
        let activationID = identifier.replacingOccurrences(of: "workflow-call-selector-", with: "")
        let table = try #require(feed.documentView as? ActivityFeedNativeTableView)
        let index = try #require(table.owner?.entries.firstIndex { entry in
            if case .supplementary(let row) = entry {
                return row.kind == .callSelector && row.id.hasSuffix("-" + activationID)
            }
            return false
        })
        table.scrollRowToVisible(index)
        feed.reflectScrolledClipView(feed.contentView)
        return try await visibleCallButton(identifier, in: feed, fixture: fixture)
    }

    func callButtonDiagnostic(_ identifier: String, in feed: ActivityFeedNativeScrollView,
                              fixture: RedesignHost) -> String {
        let responder = fixture.window.firstResponder as? NSView
        let button = remountedCallButton(identifier, in: feed)
        let candidates = allPaneViews(feed)
.compactMap { $0 as? NSButton }
            .filter { $0.accessibilityIdentifier() == identifier }
.count
        return "expected=\(identifier) ancestry=\(viewAncestry(button)), "
            + "firstResponder=\(String(describing: fixture.window.firstResponder))/\(responder?.accessibilityIdentifier() ?? "nil") "
            + "ancestry=\(viewAncestry(responder)), candidates=\(candidates), feedMatchesWindow=\(feed.window === fixture.window), "
            + "clipOrigin=\(feed.contentView.bounds.origin), documentVisible=\(feed.documentVisibleRect), "
            + "documentBounds=\(feed.documentView?.bounds ?? .zero)"
    }

    func viewAncestry(_ view: NSView?) -> String {
        var names: [String] = []
        var current = view
        while let node = current {
            names.append("\(type(of: node)):\(node.accessibilityIdentifier() ?? "nil")")
            current = node.superview
        }
        return names.joined(separator: " <- ")
    }

    func exercisePointerAndKeyboardCallSwitch(vm: WorkflowVM, harness: ParallelVMTests.SUT,
                                              taskUpdates: CurrentValueSubject<[TaskInfo], Never>,
                                              fixture: RedesignHost, diagnostic: () -> String) async throws {
        try await resourceInteractionForeground(fixture)
        let oldFeed = try #require(paneFeed(in: fixture))
        let firstID = "workflow-call-selector-specialist-1"
        let firstElement = try #require(fixture.element(firstID))
        let firstFrame = try #require(fixture.frame(firstElement))
        #expect(oldFeed.contentView.convert(oldFeed.contentView.bounds, to: nil).insetBy(dx: -1, dy: -1).contains(firstFrame))
        try clickHostedCallSelector(firstID, frame: firstFrame, fixture: fixture)
        await fixture.settle { vm.selectedActivationID == "specialist-1" }
        await vm.sidebarTask?.value
        taskUpdates.send(Array(harness.tasksBox.value.values))
        await fixture.settle {
            guard let feed = paneFeed(in: fixture), feed !== oldFeed else { return false }
            return vm.runSidebar.activationID == "specialist-1"
                && vm.selectedActivity?.columns.first?.task.taskID == "task-specialist-1"
                && feedContainsTaskRow("task-specialist-1", feed: feed)
        }

        let firstFeed = try #require(paneFeed(in: fixture), Comment(rawValue: diagnostic()))
        #expect(firstFeed !== oldFeed, "Pointer selection mounts a new execution feed")
        let firstButton = try await visibleCallButton(firstID, in: firstFeed, fixture: fixture)
        let firstButtonFrame = try #require(fixture.frame(firstButton))
        #expect(firstFeed.contentView.convert(firstFeed.contentView.bounds, to: nil).contains(firstButtonFrame))
        #expect(fixture.window.firstResponder !== firstButton,
                "Pointer selection does not programmatically focus the remounted selector")
        try await revealTranscriptRow(taskID: "task-specialist-1", text: "Transcript of call one", feed: firstFeed, fixture: fixture)

        let secondID = "workflow-call-selector-specialist-2"
        let secondButton = try await revealCallButtonForInput(secondID, in: firstFeed, fixture: fixture)
        #expect(fixture.window.makeFirstResponder(secondButton))
        try sendSpaceKey(in: fixture.window)
        await fixture.settle { vm.selectedActivationID == "specialist-2" }
        await vm.sidebarTask?.value
        taskUpdates.send(Array(harness.tasksBox.value.values))
        await fixture.settle {
            guard let feed = paneFeed(in: fixture), feed !== firstFeed,
                  vm.selectedActivity?.columns.first?.task.taskID == "task-specialist-2" else { return false }
            return vm.selectedActivationID == "specialist-2"
                && feedContainsTaskRow("task-specialist-2", feed: feed)
        }

        let secondFeed = try #require(paneFeed(in: fixture), Comment(rawValue: diagnostic()))
        #expect(secondFeed !== firstFeed, "Keyboard selection mounts a new execution feed")
        _ = try await visibleCallButton(secondID, in: secondFeed, fixture: fixture)
        await fixture.settle {
            guard let current = remountedCallButton(secondID, in: secondFeed),
                  let frame = fixture.frame(current),
                  secondFeed.contentView.convert(secondFeed.contentView.bounds, to: nil).contains(frame) else { return false }
            return fixture.window.firstResponder === current
        }
        let currentButton = try #require(remountedCallButton(secondID, in: secondFeed),
                                         Comment(rawValue: callButtonDiagnostic(secondID, in: secondFeed, fixture: fixture)))
        let currentFrame = try #require(fixture.frame(currentButton))
        #expect(secondFeed.contentView.convert(secondFeed.contentView.bounds, to: nil).contains(currentFrame),
                Comment(rawValue: callButtonDiagnostic(secondID, in: secondFeed, fixture: fixture)))
        #expect(fixture.window.firstResponder === currentButton,
                Comment(rawValue: callButtonDiagnostic(secondID, in: secondFeed, fixture: fixture)))
    }

    func clickHostedCallSelector(_ identifier: String, frame: CGRect, fixture: RedesignHost) throws {
        let buttons = fixture.descendants.compactMap { $0 as? NSButton }
        let control = try #require(buttons.first { $0.accessibilityIdentifier() == identifier })
        let nativeFrame = control.convert(control.bounds, to: nil)
        try #require(nativeFrame.insetBy(dx: -1, dy: -1).contains(CGPoint(x: frame.midX, y: frame.midY)))
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let mouseDown = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        let mouseUp = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0
        ))
        NSApp.postEvent(mouseUp, atStart: false)
        fixture.window.sendEvent(mouseDown)
    }

    func sendSpaceKey(in window: NSWindow) throws {
        let keyDown = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: 49
        ))
        let keyUp = try #require(NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: 49
        ))
        NSApp.postEvent(keyDown, atStart: true)
        NSApp.postEvent(keyUp, atStart: false)
    }
}
