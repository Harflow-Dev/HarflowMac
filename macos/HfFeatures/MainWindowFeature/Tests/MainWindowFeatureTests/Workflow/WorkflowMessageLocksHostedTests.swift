import AppKit
import Combine
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - WorkflowMessageLocksHostedTests

/// Hosted visual checks for the approved ordinary workflow message lock routes.
@MainActor @Suite(.serialized)
struct WorkflowMessageLocksHostedTests {
    private enum Surface: Equatable {
        case lanes
        case graphWorker
        case nestedOrchestrator
    }

    private struct Case {
        let name: String
        let status: String
        let surface: Surface
        let unsupported: Bool
        let taskIDs: [String]
        let expectedLock: String?
    }

    @Test func givenOrdinaryWorkflowMessageRoutes_whenHostedAcrossSizesAndAppearances_thenEachSurfaceStaysLocked() async throws {
        let cases = [
            Case(name: "lanes-completed", status: "completed", surface: .lanes, unsupported: false,
                 taskIDs: ["lane-one", "lane-two", "lane-three"], expectedLock: "Messages are off — this run is complete"),
            Case(name: "lanes-cancelling", status: "cancelling", surface: .lanes, unsupported: false,
                 taskIDs: ["lane-one", "lane-two"], expectedLock: "Messages are off — this run is cancelling"),
            Case(name: "cancelled-node-locked", status: "cancelled", surface: .graphWorker, unsupported: false,
                 taskIDs: ["worker-task"], expectedLock: "Messages are off — this run was cancelled"),
            Case(name: "lanes-unsupported", status: "running", surface: .lanes, unsupported: true,
                 taskIDs: ["lane-one", "lane-two"], expectedLock: nil),
            Case(name: "cancelled-orchestrator-locked", status: "cancelled", surface: .nestedOrchestrator,
                 unsupported: false, taskIDs: ["orchestrator-task"],
                 expectedLock: "Messages are off — this run was cancelled"),
            Case(name: "cancelled-orchestrator-fallback", status: "cancelled", surface: .nestedOrchestrator,
                 unsupported: false, taskIDs: [], expectedLock: "Messages are off — this run was cancelled")
        ]
        // 1280×800 is the previously qualified regular hosted size; 1000×620 is the supported minimum.
        let sizes = [CGSize(width: 1000, height: 620), CGSize(width: 1280, height: 800)]
        for testCase in cases {
            for appearance in [ColorScheme.light, .dark] {
                for size in sizes {
                    try await verify(testCase, appearance: appearance, size: size)
                }
            }
        }
    }

    // swiftlint:disable function_body_length
    @Test func givenCachedNestedOrchestrator_whenReselectedAfterCancellation_thenAdmissionAndMountedLockRefreshImmediately() async throws {
        let taskID = "cached-orchestrator-task"
        let vm = WorkflowPreview.make(run: true)
        defer { vm.didDisappear() }
        var raw = try #require(vm.selectedRun?.raw)
        raw["workflow_run_id"] = .string("cached-nested-run")
        raw["parent_workflow_run_id"] = .string("cached-parent-run")
        raw["status"] = .string("running")
        raw["definition"] = .object(vm.definition)
        raw["activations"] = .array([.object([
            "id": .string("cached-orchestrator-execution"),
            "node_id": .string(WorkflowStandalone.orchestratorID),
            "role": .string("orchestrator"),
            "status": .string("running"),
            "tasks": .array([.object(["task_id": .string(taskID), "status": .string("running")])])
        ])])
        vm.selectedRun = WorkflowRunModel(raw: raw)
        WorkflowPreview.synchronizeRun(vm)
        vm.selectStandalone(WorkflowStandalone.orchestratorID)

        let parallelTests = ParallelVMTests()
        let task = parallelTests.task(id: taskID, group: "workflow-message-locks", sessionID: "cached-workflow-session")
        let tasks = CurrentValueSubject<[TaskInfo], Never>([task])
        let harness = parallelTests.makeSUT(tasksPublisher: tasks.eraseToAnyPublisher())
        harness.tasksBox.value[taskID] = task
        harness.itemsBox.value[taskID] = [PreviewFixtures.textItem("Cached nested orchestrator activity")]
        harness.availabilityBox.value[taskID] = .available
        vm.parallel = harness.sut

        let scratch = ScratchDefaults(label: "stage3-cached-orchestrator-\(UUID().uuidString)")
        scratch.defaults.set("Graph", forKey: "workflowViewMode")
        defer { scratch.remove() }
        let fixture = RedesignHost(
            WorkflowView(vm).defaultAppStorage(scratch.defaults),
            size: CGSize(width: 1280, height: 800)
        )
        defer { fixture.close() }
        fixture.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        vm.didAppear()

        await fixture.settle {
            vm.runSidebar.header.kind == .orchestrator
                && vm.selectedActivity?.columns.first?.task.taskID == taskID
                && fixture.element("workflow-selected-sidebar") != nil
                && fixture.element("Send") != nil
        }
        let inspector = try #require(vm.selectedActivity)
        let originalColumn = try #require(inspector.columns.first)
        #expect(originalColumn.messageLock == nil)
        #expect(originalColumn.messageAdmission == inspector.workflowMessageAdmission)
        let staleSend = try #require(originalColumn.onSubmitMessage)

        // Cache the inspector, then select it again while the phase is still running.
        vm.selectNodes([], primary: nil)
        await vm.sidebarTask?.value
        #expect(vm.selectedActivity == nil)
        vm.selectStandalone(WorkflowStandalone.orchestratorID)
        await vm.sidebarTask?.value
        #expect(vm.selectedActivity === inspector)
        let resumedColumn = try #require(inspector.columns.first)
        #expect(resumedColumn.messageAdmission != nil)
        #expect(resumedColumn.messageAdmission == inspector.workflowMessageAdmission)
        #expect(resumedColumn.messageLock == nil)
        #expect(!staleSend("Stale after returning to the cached inspector", false))

        // Suspend the same cached inspector across a terminal phase change.
        vm.selectNodes([], primary: nil)
        await vm.sidebarTask?.value
        var cancelled = raw
        cancelled["status"] = .string("cancelled")
        vm.selectedRun = WorkflowRunModel(raw: cancelled)
        WorkflowPreview.synchronizeRun(vm)
        await vm.sidebarTask?.value
        vm.selectStandalone(WorkflowStandalone.orchestratorID)
        await vm.sidebarTask?.value

        #expect(vm.selectedActivity === inspector)
        let cancelledColumn = try #require(inspector.columns.first)
        #expect(cancelledColumn.messageAdmission != nil)
        #expect(cancelledColumn.messageAdmission == inspector.workflowMessageAdmission)
        #expect(cancelledColumn.messageLock == .runCancelled)
        #expect(cancelledColumn.onSubmitMessage?("Blocked after cancellation", false) == false)
        await fixture.settle { fixture.element("Messages are off — this run was cancelled") != nil }
        #expect(fixture.element("Messages are off — this run was cancelled") != nil,
                "The mounted cached inspector displays the current cancelled phase")
    }

    // swiftlint:enable function_body_length

    // The fixture, exact surface assertions and capture stay together so the evidence names the route it verifies.
    // swiftlint:disable function_body_length
    // swiftlint:disable cyclomatic_complexity
    private func verify(_ testCase: Case, appearance: ColorScheme, size: CGSize) async throws {
        let vm = WorkflowPreview.make(run: true)
        defer { vm.didDisappear() }
        let nested = testCase.surface == .nestedOrchestrator
        var raw = try #require(vm.selectedRun?.raw)
        raw["workflow_run_id"] = .string("message-lock-run")
        raw["status"] = .string(testCase.status)
        if nested { raw["parent_workflow_run_id"] = .string("message-lock-parent") }
        let nodeDefinitions: [[String: JSONValue]] = switch testCase.surface {
        case .lanes:
            testCase.taskIDs.enumerated().map { index, id in
                ["id": .string("lane-node-\(index)"), "type": .string("agent"), "title": .string("Lane \(id)")]
            } + (testCase.name == "lanes-cancelling" ? [[
                "id": .string("never-issued-node"), "type": .string("agent"), "title": .string("Not started")
            ]] : [])
        case .graphWorker, .nestedOrchestrator:
            [["id": .string("work"), "type": .string("agent"), "title": .string("Worker")]]
        }
        raw["definition"] = .object(["nodes": .array(nodeDefinitions.map { .object($0) })])
        let activationRole = nested ? "orchestrator" : "node"
        let activityStatus = testCase.status == "completed" ? "completed" : "running"
        let activations = testCase.taskIDs.enumerated().map { index, taskID in
            let activationNodeID: String = switch testCase.surface {
            case .lanes: "lane-node-\(index)"
            case .graphWorker: "work"
            case .nestedOrchestrator: WorkflowStandalone.orchestratorID
            }
            return JSONValue.object([
                "id": .string("message-lock-activation-\(index)"), "role": .string(activationRole),
                "node_id": .string(activationNodeID),
                "status": .string(activityStatus),
                "tasks": .array([.object(["task_id": .string(taskID), "status": .string(activityStatus)])])
            ])
        }
        let includesNeverIssued = testCase.name == "lanes-cancelling"
        let nestedFallbackActivation: [JSONValue] = nested && testCase.taskIDs.isEmpty ? [
            .object(["id": .string("nested-orchestrator-fallback"), "role": .string("orchestrator"),
                     "node_id": .string(WorkflowStandalone.orchestratorID), "status": .string("running"), "tasks": .array([])])
        ] : []
        raw["activations"] = .array(activations + nestedFallbackActivation + (includesNeverIssued ? [
            .object(["id": .string("never-issued-activation"), "role": .string("node"), "node_id": .string("never-issued-node"),
                     "status": .string("pending"), "tasks": .array([])])
        ] : []))
        vm.selectedRun = WorkflowRunModel(raw: raw)
        WorkflowPreview.synchronizeRun(vm)
        let selectedNodeID: String? = switch testCase.surface {
        case .lanes: nil
        case .graphWorker: "work"
        case .nestedOrchestrator: WorkflowStandalone.orchestratorID
        }
        vm.selectedNodeID = selectedNodeID
        vm.primaryNodeID = selectedNodeID
        vm.selectedNodeIDs = selectedNodeID.map { [$0] } ?? []
        vm.didSubscribe = true
        vm.messagingSupported = testCase.unsupported ? false : true

        let parallelTests = ParallelVMTests()
        let tasks = try testCase.taskIDs.map { id -> TaskInfo in
            let base = parallelTests.task(id: id, status: activityStatus, group: "workflow-message-locks",
                                          sessionID: "workflow-lock-\(id)")
            var taskRaw = base.raw
            if testCase.name == "lanes-cancelling", id == "lane-one" {
                taskRaw["messages"] = .array([.object([
                    "id": .string("queued-during-cancelling"), "seq": .number(1), "status": .string("queued"),
                    "text": .string("This queued message remains cancellable."),
                    "target": .object(["kind": .string("task"), "task_id": .string(id)])
                ])])
            }
            return try #require(TaskInfo(.object(taskRaw)))
        }
        let updates = CurrentValueSubject<[TaskInfo], Never>(tasks)
        let harness = parallelTests.makeSUT(tasksPublisher: updates.eraseToAnyPublisher())
        for task in tasks {
            harness.tasksBox.value[task.taskID] = task
            harness.itemsBox.value[task.taskID] = [PreviewFixtures.textItem("Ordinary workflow message lock activity")]
            harness.availabilityBox.value[task.taskID] = .available
        }
        vm.parallel = harness.sut
        vm.applyRunMessageLock()
        vm.runSidebar = WorkflowRunSidebarPresentation.build(run: raw, nodeID: selectedNodeID, attemptID: nil)
        vm.scheduleRunSidebar()
        await vm.sidebarTask?.value

        let scratch = ScratchDefaults(label: "stage3-message-locks-\(UUID().uuidString)")
        scratch.defaults.set(testCase.surface == .lanes ? "Parallel" : "Graph", forKey: "workflowViewMode")
        defer { scratch.remove() }
        let fixture = RedesignHost(
            WorkflowView(vm).defaultAppStorage(scratch.defaults).preferredColorScheme(appearance),
            size: size, appearance: appearance
        )
        defer { fixture.close() }
        fixture.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updates.send(tasks)
        await fixture.settle {
            switch testCase.surface {
            case .lanes:
                harness.sut.columns.map(\.task.taskID).sorted() == testCase.taskIDs.sorted()
                    && matches("parallel-column-composer", in: fixture).count == tasks.count
            case .graphWorker, .nestedOrchestrator:
                if testCase.taskIDs.isEmpty {
                    fixture.element("workflow-selected-sidebar") != nil
                        && fixture.element("workflow-activity-message-composer") != nil
                } else {
                    fixture.element("workflow-selected-sidebar") != nil
                        && vm.selectedActivity?.columns.contains { $0.task.taskID == testCase.taskIDs[0] } == true
                        && matches("parallel-column-composer", in: fixture).count == 1
                }
            }
        }

        if let directory = HostedCaptureEvidence.directory("HARFLOW_STAGE3_MESSAGE_LOCKS_CAPTURE_DIR"), !testCase.taskIDs.isEmpty {
            await HostedCaptureEvidence.prepare(fixture.window, dark: appearance == .dark)
            try await HostedCaptureEvidence.record(
                directory: directory,
                subject: .init(suite: "WorkflowMessageLocksHostedTests", state: testCase.name,
                               dark: appearance == .dark, size: NSSize(width: size.width, height: size.height),
                               design: .init(route: "workflow-run/\(testCase.name)",
                                             file: "v2/scripts/states-run-questions.js",
                                             commit: "70d94ef16173b7f48bc72d4930949f3df0b0b7cd")),
                window: fixture.window, host: fixture.host
            )
        }

        switch testCase.surface {
        case .lanes:
            let laneColumns = harness.sut.columns
            #expect(Set(laneColumns.map(\.task.taskID)) == Set(testCase.taskIDs),
                    "The visual lanes target exactly the issued workflow tasks")
            #expect(fixture.element("workflow-selected-sidebar") == nil,
                    "Parallel mode renders lanes rather than a selected Graph inspector")
            let initiallyVisibleTaskIDs = laneColumns.compactMap { column in
                hasLaneComposer(column, in: fixture) ? column.task.taskID : nil
            }
            #expect(!initiallyVisibleTaskIDs.isEmpty,
                    "The hosted viewport exposes real issued-lane composers with their accessible targets")
            let laneScroll = laneScrollView(in: fixture, laneCount: laneColumns.count)
            for (index, column) in laneColumns.enumerated() {
                let composerLabel = laneComposerLabel(column)
                if matches(composerLabel, in: fixture).isEmpty, let laneScroll {
                    revealLane(at: index, in: laneScroll)
                    await fixture.settle {
                        laneScroll.documentVisibleRect.intersects(laneFrame(at: index))
                            && !matches(composerLabel, in: fixture).isEmpty
                    }
                }
                #expect(matches(composerLabel, in: fixture).count >= 1,
                        "The issued lane \(column.task.taskID) mounts its own accessible composer when revealed")
                let composer = try #require(matches(composerLabel, in: fixture).first)
                let sendLabel = column.laneMessageBoxModel.sendAccessibilityLabel ?? column.laneMessageBoxModel.buttonLabel
                let sends = matches(sendLabel, in: composer)
                #expect(!sends.isEmpty && sends.allSatisfy { TaskStoppingHostedTests.isEnabled($0) == false },
                        "The accessible Send action for \(column.task.taskID) remains disabled")
                if testCase.unsupported {
                    #expect(!hasTextEntry(in: composer),
                            "Unsupported lane messaging has no editable field or placeholder")
                    #expect(!hasAccessibleText("⌘↩ to send", in: composer), "Unsupported lane messaging has no hint")
                } else {
                    #expect(testCase.expectedLock.map { hasAccessibleText($0, in: composer) } == true,
                            "The issued lane composers show their exact phase lock copy")
                    #expect(!hasTextEntry(in: composer),
                            "Phase-locked lanes replace the editable field with the lock reason")
                }
                if includesNeverIssued, column.task.taskID == "lane-one" {
                    #expect(fixture.element("Cancel queued message") != nil,
                            "The queued bubble keeps its Cancel action while the run is cancelling")
                }
            }
            #expect(fixture.element("Send now") == nil, "Parallel lane composers never show Send now")
        case .graphWorker:
            #expect(fixture.element("workflow-selected-sidebar") != nil)
            #expect(fixture.element("workflow-selected-status") != nil,
                    "The cancelled worker is selected in the Graph inspector")
            #expect(matches("parallel-column-composer", in: fixture).count == 1,
                    "The Graph worker uses its selected inspector column")
            #expect(vm.runSidebar.header.kind == .worker)
            #expect(vm.runSidebar.node?["id"]?.stringValue == "work")
            #expect(vm.selectedActivity?.columns.first?.task.taskID == "worker-task")
            #expect(testCase.expectedLock.flatMap(fixture.element) != nil)
            #expect(fixture.element("workflow-steering-composer") == nil)
            #expect(fixture.element("workflow-activity-message-composer") == nil)
            #expect(fixture.element("Send").map { TaskStoppingHostedTests.isEnabled($0) } == false)
            #expect(fixture.element("Send now") == nil)
        case .nestedOrchestrator:
            #expect(vm.selectedRun?.parentRunID == "message-lock-parent")
            #expect(fixture.element("workflow-selected-sidebar") != nil)
            #expect(vm.runSidebar.header.kind == .orchestrator)
            #expect(vm.selectedNodeID == WorkflowStandalone.orchestratorID)
            #expect(fixture.element("workflow-steering-composer") == nil,
                    "A nested orchestrator does not route its message through root steering")
            if testCase.taskIDs.isEmpty {
                #expect(fixture.element("workflow-activity-message-composer") != nil,
                        "The nested run's fallback composer remains in the selected pane")
                #expect(matches("parallel-column-composer", in: fixture).isEmpty)
                #expect(fixture.element("Send").map { TaskStoppingHostedTests.isEnabled($0) } == false)
            } else {
                #expect(vm.selectedActivity?.columns.first?.task.taskID == "orchestrator-task")
                #expect(fixture.element("workflow-activity-message-composer") == nil)
                #expect(matches("parallel-column-composer", in: fixture).count == 1)
                #expect(matches("parallel-column-composer", in: fixture).contains {
                    fixture.string($0, "accessibilityLabel")?.hasPrefix("Messages for ") == true
                }, "The selected nested orchestrator column owns the composer")
                #expect(fixture.element("Send").map { TaskStoppingHostedTests.isEnabled($0) } == false)
            }
            #expect(testCase.expectedLock.flatMap(fixture.element) != nil)
            #expect(fixture.element("Send now") == nil)
        }
        if includesNeverIssued {
            let issuedIDs = WorkflowJSON.objects(vm.selectedRun?.raw["activations"]).flatMap { activation in
                WorkflowJSON.objects(activation["tasks"]).compactMap { $0["task_id"]?.stringValue }
            }
            #expect(issuedIDs == testCase.taskIDs,
                    "The pending activation contributes no task and cannot acquire a lane composer")
        }
    }

    // swiftlint:enable function_body_length
    // swiftlint:enable cyclomatic_complexity

    private func matches(_ label: String, in fixture: RedesignHost) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        return fixture.descendants.flatMap { fixture.elements(in: $0) }.filter {
            seen.insert(ObjectIdentifier($0)).inserted && fixture.matches($0, label)
        }
    }

    private func matches(_ label: String, in root: NSObject) -> [NSObject] {
        root.accessibilityElementsRecursively.filter { element in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityIdentifier"]
                .contains { fixtureValue(element, $0) == label }
        }
    }

    private func hasAccessibleText(_ text: String, in root: NSObject) -> Bool {
        root.accessibilityElementsRecursively.contains { element in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains {
                fixtureValue(element, $0)?.contains(text) == true
            }
        }
    }

    private func hasTextEntry(in root: NSObject) -> Bool {
        root.accessibilityElementsRecursively.contains { element in
            let role = fixtureValue(element, "accessibilityRole")
            return role == NSAccessibility.Role.textField.rawValue || role == "AXTextArea"
        }
    }

    private func fixtureValue(_ object: NSObject, _ property: String) -> String? {
        let selector = NSSelectorFromString(property)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private func laneComposerLabel(_ column: ParallelColumnModel) -> String {
        "Message \(column.laneHarnessName): \(column.title)"
    }

    private func hasLaneComposer(_ column: ParallelColumnModel, in fixture: RedesignHost) -> Bool {
        !matches(laneComposerLabel(column), in: fixture).isEmpty
    }

    private func laneScrollView(in fixture: RedesignHost, laneCount: Int) -> NSScrollView? {
        let expectedWidth = ParallelLayout.documentWidth(memberCount: laneCount,
                                                         columnWidth: ParallelLayout.minimumColumnWidth, chrome: .lane)
        return fixture.descendants.compactMap { $0 as? NSScrollView }.first { scroll in
            guard let document = scroll.documentView else { return false }
            return abs(document.frame.width - expectedWidth) < 3
        }
    }

    private func revealLane(at index: Int, in scroll: NSScrollView) {
        guard let document = scroll.documentView else { return }
        let maxOffset = max(0, document.bounds.width - scroll.contentView.bounds.width)
        let offset = min(CGFloat(index) * ParallelTestGeometry.laneStride, maxOffset)
        scroll.contentView.scroll(to: CGPoint(x: offset, y: scroll.contentView.bounds.origin.y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func laneFrame(at index: Int) -> CGRect {
        CGRect(x: CGFloat(index) * ParallelTestGeometry.laneStride, y: 0,
               width: ParallelLayout.minimumColumnWidth, height: 1)
    }
}

private extension NSObject {
    var accessibilityElementsRecursively: [NSObject] {
        let selector = NSSelectorFromString("accessibilityChildren")
        guard responds(to: selector), let children = perform(selector)?.takeUnretainedValue() as? [NSObject] else { return [self] }
        return [self] + children.flatMap(\.accessibilityElementsRecursively)
    }
}
