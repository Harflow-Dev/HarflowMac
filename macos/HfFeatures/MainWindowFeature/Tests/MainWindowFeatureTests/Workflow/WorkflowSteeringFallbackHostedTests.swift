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

struct RootApprovalHostedCase: Sendable {
    let appearance: ColorScheme
    let requestCount: Int
    let size: CGSize
}

struct InspectorCoexistenceHostedCase: Sendable {
    let appearance: ColorScheme
    let selectedApprovalCount: Int
}

@MainActor @Suite(.serialized)
struct WorkflowSteeringApprovalHostedTests {
    private let rootID = WorkflowSteeringTestFixtures.rootRunID
    // This fixture hosts the selected root conversation and its direct worker approvals in the production shell.
    // swiftlint:disable function_body_length
    @Test(arguments: [
        RootApprovalHostedCase(appearance: .light, requestCount: 1, size: CGSize(width: 1000, height: 620)),
        RootApprovalHostedCase(appearance: .light, requestCount: 1, size: CGSize(width: 1280, height: 800)),
        RootApprovalHostedCase(appearance: .light, requestCount: 5, size: CGSize(width: 1000, height: 620)),
        RootApprovalHostedCase(appearance: .light, requestCount: 5, size: CGSize(width: 1280, height: 800)),
        RootApprovalHostedCase(appearance: .dark, requestCount: 1, size: CGSize(width: 1000, height: 620)),
        RootApprovalHostedCase(appearance: .dark, requestCount: 1, size: CGSize(width: 1280, height: 800)),
        RootApprovalHostedCase(appearance: .dark, requestCount: 5, size: CGSize(width: 1000, height: 620)),
        RootApprovalHostedCase(appearance: .dark, requestCount: 5, size: CGSize(width: 1280, height: 800))
    ])
    func givenRootWorkerApprovals_whenHosted_thenSharedBodyScrollsAndResponsesStayExact(
        _ testCase: RootApprovalHostedCase
    ) async throws {
        let appearance = testCase.appearance
        let requestCount = testCase.requestCount
        let size = testCase.size
        let taskID = "orchestrator-task"
        let workerTaskIDs = (0 ..< requestCount).map { "worker-task-\($0)" }
        let episodeID = WorkflowSteeringTestFixtures.episodeID
        let turnID = WorkflowSteeringTestFixtures.turnID
        let history = try WorkflowSteeringTestFixtures.history(rootID: rootID, items: [
            WorkflowSteeringTestFixtures.historyItem(sequence: 2, kind: "requested", action: "open", episodeID: episodeID,
                                                     text: "Earlier caller message"),
            WorkflowSteeringTestFixtures.historyItem(sequence: 3, kind: "final_captured", episodeID: episodeID,
                                                     turnID: turnID, text: "Choose a release channel"),
            WorkflowSteeringTestFixtures.historyItem(sequence: 4, kind: "classified", turnID: turnID, outcome: "conversation")
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
        let (vm, base, _, _) = makeSteeringVM(repository: repository, runtimeSelection: runtimeSelection)
        defer { vm.didDisappear() }
        given(base)
.command(.value("cancel-message"), options: .value(["--monitor"]),
                            positionals: .value([rootID, "queued-recovery"]), runtime: .any)
.willReturn([:])
        var raw = WorkflowSteeringHostedTests().runningRoot()
        raw["approval_summary"] = .object(["pending_count": .number(1)])
        raw["messages"] = .array([.object([
            "id": .string("queued-recovery"), "seq": .number(1), "status": .string("queued"),
            "text": .string("Keep this queued message reachable"),
            "target": .object(["kind": .string("task"), "task_id": .string(taskID)])
        ])])
        raw["definition"] = .object(["nodes": .array(workerTaskIDs.indices.map { index in
            .object(["id": .string("worker-node-\(index)"), "title": .string("Worker \(index)")])
        })])
        raw["activations"] = .array([
            .object([
                "id": .string("orchestrator-execution"), "role": .string("orchestrator"), "status": .string("running"),
                "tasks": .array([.object(["task_id": .string(taskID), "status": .string("running")])])
            ])
        ] + workerTaskIDs.enumerated().map { index, workerTaskID in
            .object([
                "id": .string("worker-execution-\(index)"), "role": .string("node"),
                "node_id": .string("worker-node-\(index)"), "status": .string("running"),
                "tasks": .array([.object(["task_id": .string(workerTaskID), "status": .string("running")])])
            ])
        })
        var postCancelRaw = raw
        postCancelRaw["messages"] = .array([])
        given(base)
.command(.value("status"), options: .value(["--monitor-view", "--snapshot"]),
         positionals: .value([rootID]), runtime: .any)
.willReturn(["run": .object(postCancelRaw)])
        vm.selectedRun = WorkflowRunModel(raw: raw)
        vm.selectedNodeID = WorkflowStandalone.orchestratorID
        vm.primaryNodeID = WorkflowStandalone.orchestratorID
        vm.selectedNodeIDs = [WorkflowStandalone.orchestratorID]
        vm.runSidebar = WorkflowRunSidebarPresentation.build(run: raw, nodeID: WorkflowStandalone.orchestratorID, attemptID: nil)
        vm.didSubscribe = true
        let requestIDs = (0 ..< requestCount).map { "req-worker-\($0)" }
        let workerRequests = requestIDs.enumerated().map { index, id in
            approvalCaptureRequest(owner: "monitor", id: id, taskID: workerTaskIDs[index],
                                   command: "swift test --filter Suite\(index)", createdAt: Double(index),
                                   workflowMetadata: [
                                       "root_workflow_run_id": rootID, "workflow_run_id": rootID,
                                       "workflow_execution_id": "worker-execution-\(index)",
                                       "workflow_node_id": "worker-node-\(index)"
                                   ])
        }
        // The issued orchestrator approval is a separate exact-task source and must not be promoted into the root worker list.
        let orchestratorRequest = approvalCaptureRequest(owner: "monitor", id: "req-orchestrator", taskID: taskID,
                                                         command: "swift test --filter OrchestratorSuite")
        let fake = CallerApprovalCaptureFake(requests: workerRequests + [orchestratorRequest])
        let scratch = ScratchDefaults(label: "stage3-steering-approval-\(UUID().uuidString)")
        scratch.defaults.set("Graph", forKey: "workflowViewMode")
        defer { scratch.remove() }
        let fixture = RedesignHost(
            WorkflowView(vm)
.defaultAppStorage(scratch.defaults)
                .environment(\.callerApprovalUseCaseOverride, { fake })
                .preferredColorScheme(appearance),
            size: size, appearance: appearance
        )
        defer { fixture.close() }
        fixture.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        vm.startSteeringObservation()
        await fixture.settle {
            vm.steeringAuthority != nil && fixture.element("You: Earlier caller message") != nil
                && requestIDs.allSatisfy { fixture.element("approval-disclosure-\($0)") != nil }
                && fixture.element("approval-approve-\(requestIDs[0])") != nil
        }
        #expect(fake.pageCalls.filter { $0.taskID == nil && $0.workflowRunID == rootID }.count == 1,
                "The selected root makes one raw run-scoped query; the hidden default Run pane does not duplicate it")

        #expect(vm.steering.action == .reply)
        #expect(fixture.element("workflow-root-approvals") != nil, "The selected root owns the direct worker approvals")
        #expect(fixture.element("parallel-column-composer") == nil, "No inspector column is mounted in the fallback case")
        #expect(fixture.element("workflow-steering-dismiss") != nil)
        #expect(MessageBoxTranscriptStyleHostedTests.editableField(in: fixture) != nil)
        #expect(vm.activityMessageBubbles.map(\.id).contains("queued-recovery"),
                "The synthetic queue entry remains in the current run alongside root approval disclosures")
        let historyViewport = try #require(fixture.element("workflow-steering-history-viewport"))
        let viewportFrame = try #require(fixture.frame(historyViewport))
        let dismiss = try #require(fixture.element("workflow-steering-dismiss"))
        let send = try #require(fixture.element("Send"))
        let editor = try #require(MessageBoxTranscriptStyleHostedTests.editableField(in: fixture))
        let dismissFrame = try #require(fixture.frame(dismiss))
        let sendFrame = try #require(fixture.frame(send))
        let editorFrame = try #require(fixture.frame(editor))
        let paneFrame = try #require(fixture.element("workflow-selected-sidebar").flatMap { fixture.frame($0) })
        let header = try #require(fixture.element("Show workflow summary"))
        let headerFrame = try #require(fixture.frame(header))
        #expect(paneFrame.contains(headerFrame) && paneFrame.contains(sendFrame) && paneFrame.contains(editorFrame),
                "The heading and composer remain in the pane's fixed chrome")
        #expect(viewportFrame.height > 0 && paneFrame.contains(viewportFrame),
                "History and request disclosures share the pane's real bounded scroll viewport")
        #expect(!viewportFrame.intersects(headerFrame) && !viewportFrame.intersects(sendFrame) && !viewportFrame.intersects(editorFrame),
                "The heading and composer remain fixed outside the shared body viewport")
        #expect(!sendFrame.intersects(editorFrame), "Send and the composer field remain separate targets")
        #expect(approvalHitTest(sendFrame, identifier: "Send", fixture: fixture))
        for id in requestIDs {
            let disclosure = try #require(fixture.element("approval-disclosure-\(id)"))
            if fixture.element("approval-approve-\(id)") == nil {
                #expect(fixture.press(disclosure), "The exact request disclosure responds to a native accessibility press")
                await fixture.settle { fixture.element("approval-approve-\(id)") != nil }
            }
            let button = try #require(fixture.host.allApprovalViews().first { $0.accessibilityIdentifier() == "approval-approve-\(id)" })
            button.scrollToVisible(button.bounds)
            fixture.host.layoutSubtreeIfNeeded()
            let approveElement = try #require(fixture.element("approval-approve-\(id)"))
            let rejectElement = try #require(fixture.element("approval-reject-\(id)"))
            let approveVisible = try #require(fixture.frame(approveElement))
            let rejectVisible = try #require(fixture.frame(rejectElement))
            let currentViewportFrame = try #require(fixture.frame(historyViewport))
            #expect(currentViewportFrame.insetBy(dx: -1, dy: -1).contains(approveVisible)
                && currentViewportFrame.insetBy(dx: -1, dy: -1).contains(rejectVisible), "Both actions for \(id) scroll inside the shared body")
            #expect(paneFrame.contains(approveVisible) && paneFrame.contains(rejectVisible)
                && fixture.window.contentLayoutRect.contains(approveVisible) && fixture.window.contentLayoutRect.contains(rejectVisible),
                "Both actions for \(id) remain inside the pane and window")
            #expect(approvalHitTest(approveVisible, identifier: "approval-approve-\(id)", fixture: fixture))
            #expect(approvalHitTest(rejectVisible, identifier: "approval-reject-\(id)", fixture: fixture))
        }
        let firstApprovalView = try #require(fixture.host.allApprovalViews().first {
            $0.accessibilityIdentifier() == "approval-approve-\(requestIDs[0])"
        })
        let sharedScrollView = try #require(firstApprovalView.enclosingScrollView)
        let documentView = try #require(sharedScrollView.documentView)
        firstApprovalView.scrollToVisible(firstApprovalView.bounds)
        fixture.host.layoutSubtreeIfNeeded()
        let capturedApprove = try #require(fixture.element("approval-approve-\(requestIDs[0])"))
        let capturedApproveFrame = try #require(fixture.frame(capturedApprove))
        let approvalViewport = sharedScrollView.contentView.convert(sharedScrollView.contentView.bounds, to: nil)
        #expect(approvalViewport.insetBy(dx: -1, dy: -1).contains(capturedApproveFrame),
                "The captured root approval shows its full inline action inside the shared viewport")
        if requestCount > 1, approvalViewport.height >= 240 {
            let sibling = try #require(fixture.element("approval-disclosure-\(requestIDs[1])"))
            let siblingFrame = try #require(fixture.frame(sibling))
            #expect(approvalViewport.intersects(siblingFrame), "A neighboring qualified request remains visible when space permits")
        }
        if let directory = HostedCaptureEvidence.directory("HARFLOW_STAGE3_STEERING_CAPTURE_DIR") {
            await HostedCaptureEvidence.prepare(fixture.window, dark: appearance == .dark)
            try await HostedCaptureEvidence.record(
                directory: directory,
                subject: .init(
                    suite: "WorkflowSteeringApprovalHostedTests",
                    state: "root-approval-\(requestCount == 1 ? "single" : "five")",
                    dark: appearance == .dark, size: NSSize(width: size.width, height: size.height),
                    design: .init(route: "workflow-run/root-approval-\(requestCount == 1 ? "single" : "five")",
                                  file: "v2/scripts/states-root-approvals.js", commit: "5539168eee43429edc2267f2a9402daf5f9a2d15")
                ),
                window: fixture.window, host: fixture.host
            )
        }
        let offscreenDismiss = try #require(fixture.element("workflow-steering-dismiss"))
        let offscreenDismissFrame = try #require(fixture.frame(offscreenDismiss))
        documentView.scrollToVisible(documentView.convert(offscreenDismissFrame, from: nil))
        fixture.host.layoutSubtreeIfNeeded()
        let visibleDismiss = try #require(fixture.element("workflow-steering-dismiss"))
        let visibleDismissFrame = try #require(fixture.frame(visibleDismiss))
        let bodyFrameAtDismiss = sharedScrollView.contentView.convert(sharedScrollView.contentView.bounds, to: nil)
        #expect(paneFrame.contains(visibleDismissFrame) && bodyFrameAtDismiss.insetBy(dx: -1, dy: -1).contains(visibleDismissFrame),
                "Dismiss remains reachable inside the same shared body after scrolling")
        #expect(approvalHitTest(visibleDismissFrame, identifier: "workflow-steering-dismiss", fixture: fixture))
        let firstDecisionView = try #require(fixture.host.allApprovalViews().first {
            $0.accessibilityIdentifier() == "approval-approve-\(requestIDs[0])"
        })
        firstDecisionView.scrollToVisible(firstDecisionView.bounds)
        fixture.host.layoutSubtreeIfNeeded()
        let decision = try #require(fixture.element("approval-approve-\(requestIDs[0])"))
        let nativeDecision = try #require(firstDecisionView as? NSButton)
        await waitUntil(timeout: 5) { nativeDecision.isEnabled }
        #expect(nativeDecision.isEnabled, "The exact request is actionable after its current controller read settles")
        #expect(fixture.press(decision), "The request's exact native Approve target remains actionable after scrolling")
        await waitUntil(timeout: 5) { fake.responses.count == 1 }
        #expect(fake.responses == [CallerApprovalCaptureFake.Response(requestID: requestIDs[0], decision: "approve")],
                "The public response path admits the selected worker request ID, not a sibling or root action")
        guard requestCount == 5, appearance == .light, size == CGSize(width: 1000, height: 620) else { return }
        fake.requests = workerTaskIDs.enumerated().map { index, workerTaskID in
            approvalCaptureRequest(owner: "monitor", id: requestIDs[index], taskID: workerTaskID,
                                   command: "swift test --filter Suite\(index)", disposition: "decided",
                                   workflowMetadata: ["root_workflow_run_id": rootID, "workflow_run_id": rootID,
                                                       "workflow_execution_id": "worker-execution-\(index)",
                                                       "workflow_node_id": "worker-node-\(index)"])
        } + [orchestratorRequest]
        await waitUntil(timeout: 8) {
            requestIDs.allSatisfy { fixture.element("approval-approve-\($0)") == nil }
        }
        await waitUntil(timeout: 8) {
            guard let currentViewport = fixture.element("workflow-steering-history-viewport").flatMap({ fixture.frame($0) }),
                  currentViewport.height > 0,
                  let cancel = fixture.element("Cancel queued message"),
                  let cancelFrame = fixture.frame(cancel) else { return false }
            return currentViewport.height > 0 && cancelFrame.width > 0
        }
        let cancel = try #require(fixture.element("Cancel queued message"))
        let offscreenCancelFrame = try #require(fixture.frame(cancel))
        documentView.scrollToVisible(documentView.convert(offscreenCancelFrame, from: nil))
        fixture.host.layoutSubtreeIfNeeded()
        let visibleCancel = try #require(fixture.element("Cancel queued message"))
        let cancelFrame = try #require(fixture.frame(visibleCancel))
        let restoredViewport = sharedScrollView.contentView.convert(sharedScrollView.contentView.bounds, to: nil)
        #expect(restoredViewport.insetBy(dx: -1, dy: -1).contains(cancelFrame),
                "The same queued message becomes cancellable inside the viewport when approval releases space")
        #expect(approvalHitTest(cancelFrame, identifier: "Cancel queued message", fixture: fixture))
        #expect(fixture.press(visibleCancel), "The restored queued Cancel responds to a real accessibility press")
        await verify(base)
.command(.value("cancel-message"), options: .value(["--monitor"]),
                        positionals: .value([rootID, "queued-recovery"]), runtime: .any)
            .calledEventually(1, before: .seconds(5))
        await fixture.settle {
            vm.selectedRun?.id == rootID && vm.selectedRun?.raw["messages"]?.arrayValue?.isEmpty == true
        }
    }

    func approvalHitTest(_ frame: CGRect, identifier: String, fixture: RedesignHost) -> Bool {
        let screenPoint = fixture.window.convertPoint(toScreen: CGPoint(x: frame.midX, y: frame.midY))
        guard let answer = fixture.host.accessibilityHitTest(screenPoint) as? NSObject else { return false }
        var current: NSObject? = answer
        for _ in 0 ..< 8 {
            guard let element = current else { return false }
            let own = (element as? NSCell)?.controlView?.accessibilityIdentifier()
                ?? fixture.string(element, "accessibilityIdentifier") ?? ""
            if own == identifier || ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains(where: {
                fixture.string(element, $0) == identifier
            }) { return true }
            let parent = NSSelectorFromString("accessibilityParent")
            current = element.responds(to: parent) ? element.perform(parent)?.takeUnretainedValue() as? NSObject : nil
        }
        return false
    }

    // swiftlint:enable function_body_length
}

extension NSView {
    func allApprovalViews() -> [NSView] { [self] + subviews.flatMap { $0.allApprovalViews() } }
}
