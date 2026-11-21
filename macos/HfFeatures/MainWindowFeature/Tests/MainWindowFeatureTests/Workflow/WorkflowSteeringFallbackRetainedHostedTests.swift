import AppKit
import Combine
import HfRepository
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import Mockable
import MonitorCore
import SwiftEnvironment
import SwiftUI
import Testing

extension WorkflowSteeringApprovalHostedTests {
    // swiftlint:disable function_body_length
    @Test(arguments: [
        InspectorCoexistenceHostedCase(appearance: .light, selectedApprovalCount: 1),
        InspectorCoexistenceHostedCase(appearance: .dark, selectedApprovalCount: 5)
    ])
    func givenSelectedRootWithRetainedInspectorActivity_whenHostedAtMinimumWindow_thenFeedAndSteeringAndExactActionsStayUsable(
        _ testCase: InspectorCoexistenceHostedCase
    ) async throws {
        let rootID = WorkflowSteeringTestFixtures.rootRunID
        let taskID = "orchestrator-task"
        let workerTaskID = "worker-task"
        let appearance = testCase.appearance
        let history = try WorkflowSteeringTestFixtures.history(rootID: rootID, items: [
            WorkflowSteeringTestFixtures.historyItem(sequence: 2, kind: "requested", action: "open",
                                                     episodeID: WorkflowSteeringTestFixtures.episodeID,
                                                     text: "Earlier caller message"),
            WorkflowSteeringTestFixtures.historyItem(sequence: 3, kind: "final_captured",
                                                     episodeID: WorkflowSteeringTestFixtures.episodeID,
                                                     turnID: WorkflowSteeringTestFixtures.turnID,
                                                     text: "Choose a release channel"),
            WorkflowSteeringTestFixtures.historyItem(sequence: 4, kind: "classified",
                                                     turnID: WorkflowSteeringTestFixtures.turnID, outcome: "conversation")
        ])
        let endpoint = try WorkflowSteeringHostedEndpoint(
            rootID: rootID,
            status: WorkflowSteeringTestFixtures.status(state: "awaiting_caller", held: true,
                                                        eligibleActions: ["reply", "dismiss"]),
            history: history
        )
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: endpoint)
        let runtimeSelection = SteeringHostedRuntimeSelection(client: client)
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willProduce { .success(runtimeSelection.client) }
        let repository = WorkflowSteeringRepositoryImpl(tooling: tooling)
        let (vm, _, _, _) = makeSteeringVM(repository: repository, runtimeSelection: runtimeSelection)
        defer { vm.didDisappear() }
        let parallelTests = ParallelVMTests()
        var orchestratorRaw = parallelTests.task(id: taskID, status: "running").raw
        orchestratorRaw["messages"] = .array([.object([
            "id": .string("queued-recovery"), "seq": .number(1), "status": .string("queued"),
            "text": .string("Keep this queued message reachable"),
            "target": .object(["kind": .string("task"), "task_id": .string(taskID)])
        ])])
        let initialTasks = [
            try #require(TaskInfo(.object(orchestratorRaw))),
            parallelTests.task(id: workerTaskID, status: "running")
        ]
        let taskUpdates = CurrentValueSubject<[TaskInfo], Never>(initialTasks)
        let parallelHarness = parallelTests.makeSUT(tasksPublisher: taskUpdates.eraseToAnyPublisher())
        for task in initialTasks { parallelHarness.tasksBox.value[task.taskID] = task }
        parallelHarness.itemsBox.value[taskID] = [PreviewFixtures.textItem("Selected orchestrator activity")]
        parallelHarness.availabilityBox.value[taskID] = .available
        parallelHarness.itemsBox.value[workerTaskID] = [PreviewFixtures.textItem("Worker activity")]
        parallelHarness.availabilityBox.value[workerTaskID] = .available
        vm.parallel = parallelHarness.sut
        vm.selectedNodeID = WorkflowStandalone.orchestratorID
        vm.primaryNodeID = WorkflowStandalone.orchestratorID
        vm.selectedNodeIDs = [WorkflowStandalone.orchestratorID]
        var raw = WorkflowSteeringHostedTests().runningRoot()
        raw["approval_summary"] = .object(["pending_count": .number(Double(testCase.selectedApprovalCount + 1))])
        raw["definition"] = .object(["nodes": .array([
            .object(["id": .string("worker-node"), "title": .string("Worker")])
        ])])
        raw["activations"] = .array([
            .object([
                "id": .string("orchestrator-execution"), "role": .string("orchestrator"),
                "status": .string("running"), "tasks": .array([.object(["task_id": .string(taskID), "status": .string("running")])])
            ]),
            .object([
                "id": .string("worker-execution"), "role": .string("node"), "node_id": .string("worker-node"),
                "status": .string("running"), "tasks": .array([.object(["task_id": .string(workerTaskID), "status": .string("running")])])
            ])
        ])
        vm.selectedRun = WorkflowRunModel(raw: raw)
        vm.runSidebar = WorkflowRunSidebarPresentation.build(run: raw, nodeID: WorkflowStandalone.orchestratorID, attemptID: nil)
        vm.didSubscribe = true
        vm.scheduleRunSidebar()
        await vm.sidebarTask?.value
        taskUpdates.send(Array(parallelHarness.tasksBox.value.values))

        let workerRequest = approvalCaptureRequest(
            owner: "monitor", id: "req-root-worker", taskID: workerTaskID, command: "swift test --filter WorkerSuite",
            workflowMetadata: ["root_workflow_run_id": rootID, "workflow_run_id": rootID,
                               "workflow_execution_id": "worker-execution", "workflow_node_id": "worker-node"]
        )
        let selectedRequests = (0 ..< testCase.selectedApprovalCount).map { index in
            let id = index == 0 ? "req-orchestrator" : "req-orchestrator-\(index)"
            let command = "swift test --filter OrchestratorSuite-\(index) --destination platform=macOS --parallel 1"
            return (id: id, command: command,
                    request: approvalCaptureRequest(owner: "monitor", id: id, taskID: taskID,
                                                    command: command, createdAt: Double(index)))
        }
        let requestIDs = selectedRequests.map(\.id)
        let fake = CallerApprovalCaptureFake(requests: [workerRequest] + selectedRequests.map(\.request))
        let scratch = ScratchDefaults(label: "stage3-root-approval-coexist-\(UUID().uuidString)")
        scratch.defaults.set("Graph", forKey: "workflowViewMode")
        defer { scratch.remove() }
        let fixture = RedesignHost(
            WorkflowView(vm)
                .defaultAppStorage(scratch.defaults)
                .environment(\.callerApprovalUseCaseOverride, { fake })
                .preferredColorScheme(appearance),
            size: CGSize(width: 1000, height: 620), appearance: appearance
        )
        defer { fixture.close() }
        fixture.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        vm.startSteeringObservation()
        await fixture.settle {
            guard let feed = fixture.descendants.compactMap({ $0 as? ActivityFeedNativeScrollView }).first,
                  let table = feed.documentView as? ActivityFeedNativeTableView else { return false }
            let ids = table.owner?.entries.map(\.id) ?? []
            return vm.steering.action == .reply
                && vm.selectedActivity?.selectedConversationID == vm.selectedActivity?.columns.first?.id
                && vm.selectedActivity?.columns.first?.task.taskID == taskID
                && vm.selectedActivity?.columns.first?.inspectorApproval?.mounts == true
                && ids.contains("activity-scoped-approval-task-\(taskID)-\(requestIDs[0])")
                && requestIDs.allSatisfy { ids.contains("activity-scoped-approval-task-\(taskID)-\($0)") }
                && ids.contains("activity-scoped-approval-run-\(rootID)-req-root-worker")
                && ids.contains("workflow-inspector-\(taskID)-approvalStatus")
                && ids.contains("workflow-inspector-run-\(rootID)-approvalStatus")
                && ids.contains("workflow-inspector-\(rootID)-steeringControls")
                && fixture.element("workflow-steering-composer") != nil
        }

        #expect(vm.selectedActivity?.columns.first?.hidesInspectorComposer == true,
                "The root reply owns the anchored composer while the selected task remains in the shared feed")
        #expect(fixture.element("parallel-column-composer") == nil)
        let pane = try #require(fixture.element("workflow-selected-sidebar"))
        let paneView = try #require(fixture.descendants
.compactMap { $0 as? NSSplitView }
            .last { $0.isVertical }?
.arrangedSubviews
.last)
        let paneFrames = try #require(fixture.frame(pane))
        let feedViews = approvalNativeViews(paneView).compactMap { $0 as? ActivityFeedNativeScrollView }
        #expect(feedViews.count == 1, "Retained root coexistence has one native activity document")
        let feed = try #require(feedViews.first)
        let table = try #require(feed.documentView as? ActivityFeedNativeTableView)
        await fixture.settle {
            let ids = table.owner?.entries.map(\.id) ?? []
            return ids.contains("activity-scoped-approval-task-\(taskID)-\(requestIDs[0])")
                && ids.contains("activity-scoped-approval-run-\(rootID)-req-root-worker")
                && ids.contains("workflow-inspector-\(rootID)-steeringHistory-heading")
                && ids.contains("workflow-inspector-\(rootID)-steeringMessage-2")
                && ids.contains("workflow-inspector-\(rootID)-steeringMessage-3")
                && ids.contains("workflow-inspector-\(rootID)-steeringControls")
                && ids.contains("activity-feed-tail")
        }
        let entries = try #require(table.owner?.entries)
        let entryIDs = entries.map(\.id)
        let taskStatusID = "workflow-inspector-\(taskID)-approvalStatus"
        let runStatusID = "workflow-inspector-run-\(rootID)-approvalStatus"
        let taskRequestEntryIDs = requestIDs.map { "activity-scoped-approval-task-\(taskID)-\($0)" }
        let runRequestID = "activity-scoped-approval-run-\(rootID)-req-root-worker"
        let historyHeadingID = "workflow-inspector-\(rootID)-steeringHistory-heading"
        let historyIDs = [historyHeadingID, "workflow-inspector-\(rootID)-steeringMessage-2",
                          "workflow-inspector-\(rootID)-steeringMessage-3"]
        let controlsID = "workflow-inspector-\(rootID)-steeringControls"
        let tailID = "activity-feed-tail"
        #expect(taskRequestEntryIDs.allSatisfy(entryIDs.contains), "All selected task approvals retain task-scoped identities")
        #expect(entryIDs.contains(taskStatusID) && entryIDs.contains(runStatusID))
        #expect(entryIDs.contains("workflow-inspector-run-\(rootID)-caption"))
        #expect(historyIDs.allSatisfy(entryIDs.contains))
        #expect(entryIDs.contains(runRequestID) && entryIDs.contains(controlsID) && entryIDs.contains(tailID))
        let taskEntry = try #require(entries.compactMap(approvalEntry).first { $0.id == taskRequestEntryIDs[0] })
        let runEntry = try #require(entries.compactMap(approvalEntry).first { $0.id == runRequestID })
        #expect(taskEntry.source == .task(taskID))
        #expect(runEntry.source == .workflowRun(rootID) && runEntry.issuer == "Worker",
                "The selected root card preserves its exact run source and qualified worker issuer")
        #expect(fake.pageCalls.contains { $0.taskID == taskID && $0.workflowRunID == nil })
        #expect(fake.pageCalls.contains { $0.taskID == nil && $0.workflowRunID == rootID },
                "Task and root approvals use separate exact query scopes")
        let taskStatusIndex = try #require(entryIDs.firstIndex(of: taskStatusID))
        let taskCardIndices = taskRequestEntryIDs.compactMap { entryIDs.firstIndex(of: $0) }
        #expect(taskCardIndices.count == taskRequestEntryIDs.count)
        let steeringIndex = try #require(entryIDs.firstIndex(of: historyHeadingID))
        let steeringMessageIndices = historyIDs.dropFirst().compactMap { entryIDs.firstIndex(of: $0) }
        let runCardIndex = try #require(entryIDs.firstIndex(of: runRequestID))
        let runStatusIndex = try #require(entryIDs.firstIndex(of: runStatusID))
        let controlsIndex = try #require(entryIDs.firstIndex(of: controlsID))
        let tailIndex = try #require(entryIDs.firstIndex(of: tailID))
        #expect((([taskStatusIndex] + taskCardIndices).max() ?? Int.max) < steeringIndex)
        #expect(steeringMessageIndices.allSatisfy { $0 > steeringIndex && $0 < runCardIndex })
        if let outcomeIndex = entryIDs.firstIndex(of: "workflow-inspector-\(rootID)-steeringHistory-outcome") {
            #expect(outcomeIndex > (steeringMessageIndices.max() ?? steeringIndex) && outcomeIndex < runCardIndex)
        }
        #expect(runCardIndex < runStatusIndex && runStatusIndex < controlsIndex && controlsIndex < tailIndex,
                "The run cards, status, steering controls and queued-message tail keep their document order")
        #expect(entryIDs.dropFirst(tailIndex + 1).allSatisfy { $0 == "activity-feed-bottom" },
                "The queued-message tail is the last content row in the shared document")
        let innerScrolls = approvalNativeViews(feed).compactMap { $0 as? NSScrollView }.filter { $0 !== feed }
        #expect(innerScrolls.isEmpty, "Approval detail and steering content do not introduce an inner scroll view")
        let header = try #require(fixture.element("Show workflow summary"))
        let headerFrame = try #require(fixture.frame(header))
        let composer = try #require(fixture.element("workflow-steering-composer"))
        let composerFrame = try #require(fixture.frame(composer))
        let feedFrame = feed.convert(feed.bounds, to: nil)
        #expect(paneFrames.contains(headerFrame) && paneFrames.contains(feedFrame) && paneFrames.contains(composerFrame))
        #expect(headerFrame.minY >= feedFrame.maxY - 1 && composerFrame.maxY <= feedFrame.minY + 1,
                "The selected-pane header and root composer stay anchored outside the one native document")
        #expect(vm.selectedActivity?.columns.first?.workMessages.contains { $0.id == "queued-recovery" } == true,
                "The retained orchestrator task owns the queued bubble which produces the document tail")

        if let directory = HostedCaptureEvidence.directory("HARFLOW_STAGE3_STEERING_CAPTURE_DIR") {
            await HostedCaptureEvidence.prepare(fixture.window, dark: appearance == .dark)
            try await HostedCaptureEvidence.record(
                directory: directory,
                subject: .init(
                    suite: "WorkflowSteeringApprovalHostedTests",
                    state: "root-approval-retained-document-\(appearance == .dark ? "dark" : "light")-\(requestIDs.count)",
                    dark: appearance == .dark, size: NSSize(width: 1000, height: 620),
                    design: .init(route: "workflow-run/inspector-approvals-steering-minimum",
                                  file: "v2/scripts/states-inspector-approvals.js",
                                  commit: "cc963375871fe91397351f425b9f1ebb3079c77b")
                ),
                window: fixture.window, host: fixture.host
            )
        }

        let timelineIndex = try #require(entries.firstIndex { entry in
            if case .row(let row) = entry { return row.row.taskID == taskID }
            return false
        }, "The retained document includes the selected task transcript")
        let timelineRow = entries[timelineIndex]
        let timelineAnchorID = try #require(timelineRow.anchorID)
        let anchorRect = table.rect(ofRow: timelineIndex)
        activityNativeTestScroll(feed, to: anchorRect.minY + min(3, anchorRect.height / 3))
        await fixture.settle {
            guard let current = feed.owner?.state?.anchor, current.id == timelineAnchorID,
                  feed.owner?.state?.followLive.isFollowing == false else { return false }
            let rowOffset = table.rect(ofRow: timelineIndex).minY - feed.documentVisibleRect.minY
            return abs(current.relativeOffset - rowOffset) < 3
        }
        let anchor = try #require(feed.owner?.state?.anchor)
        try #require(anchor.id == timelineAnchorID, "Pause on the requested task transcript row before inserting history")
        let measuredRowOffset = table.rect(ofRow: timelineIndex).minY - feed.documentVisibleRect.minY
        #expect(abs(anchor.relativeOffset - measuredRowOffset) < 3,
                "The captured reading offset belongs to the requested task row's current viewport geometry")
        let anchorID = anchor.id
        let relativeOffset = anchor.relativeOffset
        let insertedSequence: Int64 = 10
        vm.steeringDisplay.presentation.messages.append(.init(id: insertedSequence, isCaller: false,
                                                               text: "Inserted steering history row"))
        let insertedHistoryID = "workflow-inspector-\(rootID)-steeringMessage-\(insertedSequence)"
        await fixture.settle { table.owner?.entries.contains { $0.id == insertedHistoryID } == true }
        #expect(table.owner?.entries.contains { $0.id == insertedHistoryID } == true)
        #expect(feed.owner?.state?.followLive.isFollowing == false)
        #expect(feed.owner?.state?.anchor?.id == anchorID,
                "A steering-history insertion keeps the paused reader on the same task row")
        #expect(abs((feed.owner?.state?.anchor?.relativeOffset ?? .infinity) - relativeOffset) < 3,
                "The selected task row keeps its screen offset through the structural insertion")

        let taskTargets = requestIDs.count == 1
            ? [requestIDs[0]]
            : [requestIDs[0], requestIDs[requestIDs.count - 1]]
        let approvalTargets: [(ActivityFeedApprovalEntry.Source, String)] = taskTargets.map { (.task(taskID), $0) }
            + [(.workflowRun(rootID), "req-root-worker")]
        for size in [CGSize(width: 1000, height: 620), CGSize(width: 1280, height: 800), CGSize(width: 1000, height: 620)] {
            fixture.window.setContentSize(size)
            await fixture.settle {
                fixture.host.layoutSubtreeIfNeeded()
                return abs(fixture.host.bounds.width - size.width) < 1
                    && abs(fixture.host.bounds.height - size.height) < 1
                    && paneView.convert(paneView.bounds, to: nil).height > 0
                    && feed.window === fixture.window
            }
            let currentPane = try #require(fixture.frame(pane))
            let currentHeader = try #require(fixture.frame(header))
            let currentComposer = try #require(fixture.frame(composer))
            let currentFeed = feed.convert(feed.bounds, to: nil)
            #expect(currentPane.contains(currentHeader) && currentPane.contains(currentFeed) && currentPane.contains(currentComposer))
            #expect(currentHeader.minY >= currentFeed.maxY - 1 && currentComposer.maxY <= currentFeed.minY + 1,
                    "The header and composer remain anchored at \(size)")
            #expect(feedViews.count == 1 && feed.owner?.positioned == true,
                    "Resizing preserves the same selected native document")
            for (source, requestID) in approvalTargets {
                try await verifyDecisionControls(source: source, requestID: requestID, size: size,
                                                 feed: feed, fixture: fixture)
            }
        }

        let finalEntries = try #require(table.owner?.entries)
        let finalTail = try #require(finalEntries.firstIndex { $0.id == tailID })
        table.scrollRowToVisible(finalTail)
        feed.reflectScrolledClipView(feed.contentView)
        await fixture.settle { fixture.element("Cancel queued message") != nil }
        let cancel = try #require(fixture.element("Cancel queued message"))
        let cancelFrame = try #require(fixture.frame(cancel))
        #expect(feed.contentView.convert(feed.contentView.bounds, to: nil).contains(cancelFrame),
                "The pending root message is reachable at the document tail")
        #expect(approvalHitTest(cancelFrame, identifier: "Cancel queued message", fixture: fixture))
    }

    @Test func givenTaskAndRunRequestsShareRawID_whenProjected_thenNativeIdentityAndRevealRemainSourceScoped() {
        let taskRequest = approvalCaptureRequest(owner: "monitor", id: "shared-request", taskID: "selected-task")
        let runRequest = approvalCaptureRequest(owner: "monitor", id: "shared-request", taskID: "worker-task")
        func card(_ request: CallerApprovalRequest) -> CallerApprovalCardModel {
            CallerApprovalCardModel(request: request, action: CallerApprovalAction.build(request), pending: true,
                                    expanded: false, canRespond: true, notice: nil, submitting: false)
        }
        let taskEntry = ActivityFeedApprovalEntry(source: .task("selected-task"), card: card(taskRequest))
        let runEntry = ActivityFeedApprovalEntry(source: .workflowRun("root-run"), card: card(runRequest), issuer: "Worker")
        let taskToken = UUID()
        let runToken = UUID()
        let taskReveal = ActivityFeedApprovalReveal(source: taskEntry.source,
            reveal: CallerApprovalReveal(requestID: "shared-request", token: taskToken))
        let runReveal = ActivityFeedApprovalReveal(source: runEntry.source,
            reveal: CallerApprovalReveal(requestID: "shared-request", token: runToken))

        #expect(taskEntry.card.id == runEntry.card.id)
        #expect(taskEntry.id == "activity-scoped-approval-task-selected-task-shared-request")
        #expect(runEntry.id == "activity-scoped-approval-run-root-run-shared-request")
        #expect(taskEntry.id != runEntry.id)
        #expect(taskReveal.source == taskEntry.source && taskReveal.requestID == taskEntry.card.id
                    && taskReveal.token == taskToken)
        #expect(runReveal.source == runEntry.source && runReveal.requestID == runEntry.card.id
                    && runReveal.token == runToken)
    }

    private func approvalEntry(_ entry: ActivityFeedNativeEntry) -> ActivityFeedApprovalEntry? {
        guard case .scopedApproval(let scoped, _) = entry else { return nil }
        return scoped
    }

    private func verifyDecisionControls(source: ActivityFeedApprovalEntry.Source, requestID: String,
                                        size: CGSize, feed: ActivityFeedNativeScrollView, fixture: RedesignHost) async throws {
        let table = try #require(feed.documentView as? ActivityFeedNativeTableView)
        let entry = try #require(table.owner?.entries.compactMap(approvalEntry).first {
            $0.source == source && $0.card.id == requestID
        }, "A native card matches the exact approval authority and request ID")
        let row = try #require(table.owner?.entries.firstIndex { $0.id == entry.id })
        table.scrollRowToVisible(row)
        feed.reflectScrolledClipView(feed.contentView)
        let disclosureID = "approval-disclosure-\(requestID)"
        let approveID = "approval-approve-\(requestID)"
        let rejectID = "approval-reject-\(requestID)"
        await fixture.settle { fixture.element(disclosureID) != nil }
        if fixture.element(approveID) == nil {
            let disclosure = try #require(fixture.element(disclosureID))
            #expect(fixture.press(disclosure), "The source-scoped approval disclosure expands in the shared document")
        }
        await fixture.settle { fixture.element(approveID) != nil && fixture.element(rejectID) != nil }
        for identifier in [approveID, rejectID] {
            let target = DecisionHitTarget(identifier: identifier, source: source, requestID: requestID,
                                           entryID: entry.id, size: size)
            let frame = try await atomicDecisionFrame(target, feed: feed, fixture: fixture)
            let viewport = feed.contentView.convert(feed.contentView.bounds, to: nil)
            #expect(viewport.contains(frame) && fixture.window.contentLayoutRect.contains(frame),
                    "The exact \(source) action \(identifier) is fully reachable in its single native document")
        }
    }

    private func atomicDecisionFrame(_ target: DecisionHitTarget, feed: ActivityFeedNativeScrollView,
                                     fixture: RedesignHost) async throws -> CGRect {
        guard let document = feed.documentView else {
            Issue.record("Activity document is missing while revealing \(target.identifier)")
            return .zero
        }
        let table = try #require(document as? ActivityFeedNativeTableView)
        let deadline = Date().addingTimeInterval(5)
        var latest = "no current AX frame for \(target.identifier)"
        while Date() < deadline {
            fixture.host.layoutSubtreeIfNeeded()
            guard let row = table.owner?.entries.firstIndex(where: { $0.id == target.entryID }),
                  let currentEntry = table.owner?.entries[row].flatMapApprovalEntry,
                  currentEntry.source == target.source, currentEntry.card.id == target.requestID,
                  let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ActivityFeedNativeCell,
                  cell.entryID == target.entryID, cell.host?.rootView.entry.id == target.entryID else {
                latest = decisionRowDiagnostic(target, table: table, feed: feed)
                if let row = table.owner?.entries.firstIndex(where: { $0.id == target.entryID }) {
                    table.scrollRowToVisible(row)
                    feed.reflectScrolledClipView(feed.contentView)
                }
                try? await Task.sleep(for: .milliseconds(20))
                continue
            }
            guard let element = fixture.element(target.identifier), let frame = fixture.frame(element) else {
                latest = decisionRowDiagnostic(target, table: table, feed: feed)
                    + ", current view=\(ObjectIdentifier(cell)), AX action missing"
                try? await Task.sleep(for: .milliseconds(20))
                continue
            }
            let viewport = feed.contentView.convert(feed.contentView.bounds, to: nil)
            let hit = approvalHitTest(frame, identifier: target.identifier, fixture: fixture)
            latest = decisionHitDiagnostic(DecisionHitEvidence(target: target, frame: frame,
                                                               element: element, cell: cell,
                                                               feed: feed, table: table, fixture: fixture))
            if viewport.insetBy(dx: -1, dy: -1).contains(frame), hit {
                return frame
            }
            if !viewport.insetBy(dx: -1, dy: -1).contains(frame) {
                document.scrollToVisible(document.convert(frame, from: nil))
                feed.reflectScrolledClipView(feed.contentView)
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        try #require(false, Comment(rawValue: "Exact current native action hit did not settle: \(latest)"))
        return .zero
    }

    private func decisionRowDiagnostic(_ target: DecisionHitTarget, table: ActivityFeedNativeTableView,
                                       feed: ActivityFeedNativeScrollView) -> String {
        let row = table.owner?.entries.firstIndex(where: { $0.id == target.entryID })
        let entry = row.flatMap { table.owner?.entries[$0] }
        let card = entry?.flatMapApprovalEntry
        let cell = row.flatMap { table.view(atColumn: 0, row: $0, makeIfNecessary: false) as? ActivityFeedNativeCell }
        let visible = feed.documentVisibleRect
        return "id=\(target.identifier), size=\(target.size), source=\(target.source), row=\(row.map(String.init) ?? "missing"), "
            + "entry=\(entry?.id ?? "missing"), card=\(card?.card.id ?? "missing"), "
            + "cell=\(cell.map { String(describing: ObjectIdentifier($0)) } ?? "missing"), "
            + "cellEntry=\(String(describing: cell?.entryID)), cellRoot=\(String(describing: cell?.host?.rootView.entry.id)), "
            + "clip=\(visible), clipFrame=\(feed.contentView.convert(feed.contentView.bounds, to: nil)), "
            + "document=\(table.bounds), offset=\(visible.origin)"
    }

    private func decisionHitDiagnostic(_ evidence: DecisionHitEvidence) -> String {
        let target = evidence.target
        let frame = evidence.frame
        let feed = evidence.feed
        let fixture = evidence.fixture
        let table = evidence.table
        let screenPoint = fixture.window.convertPoint(toScreen: CGPoint(x: frame.midX, y: frame.midY))
        let axHit = fixture.host.accessibilityHitTest(screenPoint) as? NSObject
        var axChain: [String] = []
        var current = axHit
        for _ in 0 ..< 8 {
            guard let value = current else { break }
            let identifierValue = fixture.string(value, "accessibilityIdentifier") ?? ""
            let label = fixture.string(value, "accessibilityLabel") ?? fixture.string(value, "accessibilityTitle") ?? ""
            axChain.append("\(type(of: value))#\(identifierValue):\(label)")
            let parent = NSSelectorFromString("accessibilityParent")
            current = value.responds(to: parent) ? value.perform(parent)?.takeUnretainedValue() as? NSObject : nil
        }
        let windowPoint = fixture.window.convertPoint(fromScreen: screenPoint)
        let nativeParent = evidence.feed.superview
        let nativePoint = nativeParent?.convert(windowPoint, from: nil) ?? .zero
        let nativeHit = nativeParent?.hitTest(nativePoint)
        var nativeChain: [String] = []
        var native = nativeHit
        for _ in 0 ..< 12 {
            guard let view = native else { break }
            nativeChain.append("\(type(of: view))#\(view.accessibilityIdentifier())")
            native = view.superview
        }
        let row = table.owner?.entries.firstIndex(where: { $0.id == target.entryID })
        let currentEntryID = row.flatMap { table.owner?.entries[$0].id } ?? "missing"
        let currentCardID = row.flatMap { table.owner?.entries[$0].flatMapApprovalEntry?.card.id } ?? "missing"
        let visible = feed.documentVisibleRect
        return "id=\(target.identifier), source=\(target.source), frame=\(frame), AX-hit=\(axChain), "
            + "native-hit=\(nativeChain), size=\(target.size), entry=\(currentEntryID), card=\(currentCardID), "
            + "element=\(ObjectIdentifier(evidence.element)), cell=\(ObjectIdentifier(evidence.cell)), "
            + "cellEntry=\(String(describing: evidence.cell.entryID)), "
            + "cellRoot=\(String(describing: evidence.cell.host?.rootView.entry.id)), clip=\(visible), "
            + "clipFrame=\(feed.contentView.convert(feed.contentView.bounds, to: nil)), document=\(table.bounds), offset=\(visible.origin)"
    }

}

private extension ActivityFeedNativeEntry {
    var flatMapApprovalEntry: ActivityFeedApprovalEntry? {
        guard case .scopedApproval(let scoped, _) = self else { return nil }
        return scoped
    }
}

private struct DecisionHitTarget {
    let identifier: String
    let source: ActivityFeedApprovalEntry.Source
    let requestID: String
    let entryID: String
    let size: CGSize
}

private struct DecisionHitEvidence {
    let target: DecisionHitTarget
    let frame: CGRect
    let element: NSObject
    let cell: ActivityFeedNativeCell
    let feed: ActivityFeedNativeScrollView
    let table: ActivityFeedNativeTableView
    let fixture: RedesignHost
}

    // swiftlint:enable function_body_length

private func approvalNativeViews(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(approvalNativeViews)
}
