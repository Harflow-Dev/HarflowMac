import AppKit
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import SwiftEnvironment
import SwiftUI
import Testing

// MARK: - WorkflowSteeringHostedTests approved state matrix

@MainActor
extension WorkflowSteeringHostedTests {
    private nonisolated static let captureCases = [
        MatrixCapture(size: CGSize(width: 1000, height: 620), appearance: .light),
        MatrixCapture(size: CGSize(width: 1000, height: 620), appearance: .dark),
        MatrixCapture(size: CGSize(width: 1440, height: 900), appearance: .light),
        MatrixCapture(size: CGSize(width: 1440, height: 900), appearance: .dark)
    ]
    private static let captureDesignCommit = "70d94ef16173b7f48bc72d4930949f3df0b0b7cd"

    @Test(arguments: Self.captureCases.map { MatrixCase(state: "selected", capture: $0) }
        + Self.captureCases.map { MatrixCase(state: "open", capture: $0) }
        + Self.captureCases.map { MatrixCase(state: "question", capture: $0) }
        + Self.captureCases.map { MatrixCase(state: "waiting", capture: $0) })
    func givenApprovedConversationState_whenHostedInProductionShell_thenControlsAndCopyMatch(
        _ testCase: MatrixCase
    ) async throws {
        try await captureApprovedState(testCase.state, size: testCase.capture.size, appearance: testCase.capture.appearance)
    }

    @Test(arguments: Self.captureCases.map { MatrixCase(state: "cancelling", capture: $0) }
        + Self.captureCases.map { MatrixCase(state: "unknown", capture: $0) }
        + Self.captureCases.map { MatrixCase(state: "stale", capture: $0) }
        + Self.captureCases.map { MatrixCase(state: "expired", capture: $0) })
    func givenApprovedLockOrRetargetState_whenHostedInProductionShell_thenControlsAndCopyMatch(
        _ testCase: MatrixCase
    ) async throws {
        try await captureApprovedState(testCase.state, size: testCase.capture.size, appearance: testCase.capture.appearance)
    }

    @Test(arguments: Self.captureCases.map { MatrixCase(state: "dismissing", capture: $0) }
        + Self.captureCases.map { MatrixCase(state: "dismissed", capture: $0) }
        + Self.captureCases.map { MatrixCase(state: "refused", capture: $0) })
    func givenApprovedSettlementOrRecoveryState_whenHostedInProductionShell_thenControlsAndCopyMatch(
        _ testCase: MatrixCase
    ) async throws {
        try await captureApprovedState(testCase.state, size: testCase.capture.size, appearance: testCase.capture.appearance)
    }

    // This hosted fixture keeps setup, assertions, and capture metadata together so each matrix invocation is self-contained.
    // swiftlint:disable function_body_length
    private func captureApprovedState(_ name: String, size: CGSize, appearance: ColorScheme) async throws {
        let fixtureModel = try scenario(name)
        let endpoint = try WorkflowSteeringHostedEndpoint(
            rootID: rootID, status: fixtureModel.status, history: fixtureModel.history
        )
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: endpoint)
        let runtimeSelection = SteeringHostedRuntimeSelection(client: client)
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willProduce { .success(runtimeSelection.client) }
        let repository = WorkflowSteeringRepositoryImpl(tooling: tooling)
        let (vm, _, _, routing) = makeSteeringVM(repository: repository, runtimeSelection: runtimeSelection)
        defer { vm.didDisappear() }
        vm.selectedRun = fixtureModel.run
        vm.selectedNodeID = WorkflowStandalone.orchestratorID
        vm.primaryNodeID = WorkflowStandalone.orchestratorID
        vm.selectedNodeIDs = [WorkflowStandalone.orchestratorID]
        vm.runSidebar = WorkflowRunSidebarPresentation.build(
            run: fixtureModel.run.raw, nodeID: WorkflowStandalone.orchestratorID, attemptID: nil
        )
        // WorkflowView owns the ordinary subscription lifecycle. This fixture marks that lifecycle ready,
        // then starts only the real steering observation path under test.
        vm.didSubscribe = true
        let scratch = ScratchDefaults(label: "stage3-steering-\(name)-\(UUID().uuidString)")
        scratch.defaults.set("Graph", forKey: "workflowViewMode")
        defer { scratch.remove() }
        let fixture = RedesignHost(
            WorkflowView(vm).defaultAppStorage(scratch.defaults).preferredColorScheme(appearance),
            size: size, appearance: appearance
        )
        defer { fixture.close() }
        fixture.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await fixture.settle { fixture.element("workflow-steering-panel") != nil }
        vm.startSteeringObservation()
        await fixture.settle {
            vm.steeringAuthority != nil && (fixtureModel.expectedStatus.map { fixture.element($0) != nil } ?? true)
        }

        #expect(vm.steeringAuthority != nil, "The rendered controls are backed by a real checked public observation")
        #expect(vm.steering.action == fixtureModel.expectedAction)
        #expect(vm.steering.canDismiss == fixtureModel.canDismiss)
        #expect(vm.steering.placeholder == fixtureModel.expectedPlaceholder)
        for text in fixtureModel.expectedText { #expect(fixture.element(text) != nil, "Missing approved copy: \(text)") }
        #expect((fixture.element("workflow-steering-dismiss") != nil) == fixtureModel.canDismiss)
        #expect((fixture.element("workflow-steering-needs-you") != nil) == fixtureModel.opensNeedsYou)
        if fixtureModel.expectedAction == nil {
            #expect(MessageBoxTranscriptStyleHostedTests.editableField(in: fixture) == nil,
                    "A locked state exposes the lock copy instead of an editable field")
            #expect(TaskStoppingHostedTests.isEnabled(try #require(fixture.element("Send"))) == false)
        } else {
            let editor = try #require(MessageBoxTranscriptStyleHostedTests.editableField(in: fixture))
            #expect(editor.isEnabled, "Editability follows exact current action authority")
            #expect(fixture.element("workflow-steering-composer") != nil)
            #expect(TaskStoppingHostedTests.isEnabled(try #require(fixture.element("Send"))) == false,
                    "The empty draft keeps Send disabled while the current action authority remains enabled")
        }
        if fixtureModel.opensNeedsYou {
            vm.openSteeringNeedsYou(authority: vm.steeringAuthority)
            await verify(routing).showNeedsYou(itemID: .value(nil)).called(1)
            #expect(endpoint.actions.isEmpty, "Opening Needs you does not create a steering request")
        }
        if name == "dismissed" {
            let resume = try #require(fixture.element("workflow-steering-resume"))
            #expect(TaskStoppingHostedTests.isEnabled(resume) == false)
            #expect(fixture.string(resume, "accessibilityHelp") == fixtureModel.resumeReason)
            #expect(fixture.element(fixtureModel.resumeReason ?? "") != nil,
                    "The disabled Resume reason remains visible in the hosted pane")
        }
        if name != "selected" {
            #expect(fixture.element("Not started") == nil, "The attributable public steering state owns the transcript slot")
        }
        if name == "stale" {
            let needsYouBadges = fixture.descendants.flatMap { fixture.elements(in: $0) }.filter { fixture.matches($0, "Needs you") }
            #expect(needsYouBadges.count == 1, "The checked current typed hold yields exactly one Needs you badge")
        }

        if let directory = HostedCaptureEvidence.directory("HARFLOW_STAGE3_STEERING_CAPTURE_DIR") {
            await HostedCaptureEvidence.prepare(fixture.window, dark: appearance == .dark)
            try await HostedCaptureEvidence.record(
                directory: directory,
                subject: .init(
                    suite: "WorkflowSteeringHostedTests", state: String(fixtureModel.route.dropFirst("workflow-run/".count)),
                    dark: appearance == .dark, size: NSSize(width: size.width, height: size.height),
                    design: .init(route: fixtureModel.route, file: fixtureModel.designFile, commit: Self.captureDesignCommit)
                ),
                window: fixture.window, host: fixture.host
            )
        }
    }

    // The switch is the approved-state table; keeping each route's wire state and expected copy adjacent makes review direct.
    private func scenario(_ name: String) throws -> MatrixScenario {
        let runID = rootID
        let episodeID = WorkflowSteeringTestFixtures.episodeID
        let turnID = WorkflowSteeringTestFixtures.turnID
        var raw: [String: JSONValue] = [
            "workflow_run_id": .string(runID),
            "root_workflow_run_id": .string(runID),
            "name": .string("Steering fixture"),
            "kind": .string("workflow"),
            "status": .string("running"),
            "definition": .object(["nodes": .array([])]),
            "activations": .array([])
        ]
        let status: WorkflowSteeringStatus
        let historyItems: [[String: Any]]
        let expectedAction: WorkflowSteeringAction?
        let canDismiss: Bool
        let opensNeedsYou = name == "question"
        let expectedStatus: String?
        let expectedText: [String]
        let expectedPlaceholder: String
        let designFile: String

        switch name {
        case "selected":
            status = try WorkflowSteeringTestFixtures.status(eligibleActions: ["open"], refusalCodes: [])
            historyItems = []
            expectedAction = .open
            canDismiss = false
            expectedStatus = nil
            expectedText = []
            expectedPlaceholder = "Message the orchestrator"
            designFile = "v2/scripts/states-run-actions.js"
        case "open":
            status = try WorkflowSteeringTestFixtures.status(state: "discussing", held: true, eligibleActions: ["dismiss"])
            historyItems = [WorkflowSteeringTestFixtures.historyItem(sequence: 2, kind: "requested", action: "open", episodeID: episodeID,
                                                                     text: "Earlier caller message")]
            expectedAction = nil
            canDismiss = true
            expectedStatus = "Waiting for the orchestrator to respond"
            expectedText = ["You: Earlier caller message"]
            expectedPlaceholder = "One conversation at a time — wait for the reply"
            designFile = "v2/scripts/states-run-actions.js"
        case "question":
            status = try WorkflowSteeringTestFixtures.status(eligibleActions: ["open"], refusalCodes: ["steering_question_pending"])
            raw["status"] = .string("needs_input")
            raw["input_decision_id"] = .string("decision-release-channel")
            raw["input_question"] = .string("Choose a release channel")
            raw["pending_inputs"] = .array([.object([
                "workflow_run_id": .string(runID), "decision_id": .string("decision-release-channel"),
                "question": .string("Choose a release channel")
            ])])
            historyItems = []
            expectedAction = nil
            canDismiss = false
            expectedStatus = nil
            expectedText = ["Open Needs you"]
            expectedPlaceholder = "Answer the run's open question first."
            designFile = "v2/scripts/states-run-actions.js"
        case "waiting":
            status = try WorkflowSteeringTestFixtures.status(state: "awaiting_caller", held: true,
                                                              eligibleActions: ["reply", "dismiss"])
            historyItems = [
                WorkflowSteeringTestFixtures.historyItem(sequence: 2, kind: "requested", action: "open", episodeID: episodeID,
                                                         text: "Earlier caller message"),
                WorkflowSteeringTestFixtures.historyItem(sequence: 3, kind: "final_captured", episodeID: episodeID,
                                                         turnID: turnID, text: "Choose a release channel"),
                WorkflowSteeringTestFixtures.historyItem(sequence: 4, kind: "classified", turnID: turnID, outcome: "conversation")
            ]
            expectedAction = .reply
            canDismiss = true
            expectedStatus = "The orchestrator asked a question. Reply to continue."
            expectedText = ["Orchestrator: Choose a release channel"]
            expectedPlaceholder = "Reply to the orchestrator"
            designFile = "v2/scripts/states-run-actions.js"
        case "cancelling":
            status = try WorkflowSteeringTestFixtures.status(state: "awaiting_caller", held: true,
                                                              eligibleActions: ["dismiss"])
            raw["status"] = .string("cancelling")
            historyItems = []
            expectedAction = nil
            canDismiss = true
            expectedStatus = "Cancelling the run…"
            expectedText = []
            expectedPlaceholder = "Messages are off — this run is cancelling"
            designFile = "v2/scripts/states-run-actions.js"
        case "unknown":
            status = try WorkflowSteeringTestFixtures.status(state: "delivery_unknown", held: true,
                                                              eligibleActions: ["dismiss"])
            historyItems = []
            expectedAction = nil
            canDismiss = true
            expectedStatus = "Delivery unknown"
            expectedText = []
            expectedPlaceholder = "Messages are off until delivery is settled"
            designFile = "v2/scripts/states-run-actions.js"
        case "stale":
            status = try WorkflowSteeringTestFixtures.status(state: "stale", held: true,
                                                              eligibleActions: ["retarget", "dismiss"])
            historyItems = []
            expectedAction = .retarget
            canDismiss = true
            expectedStatus = nil
            expectedText = ["The run moved on since this conversation started.", "Your next message starts a new conversation."]
            expectedPlaceholder = "Message the orchestrator"
            designFile = "v2/scripts/states-run-questions.js"
        case "expired":
            status = try WorkflowSteeringTestFixtures.status(state: "expired", held: true,
                                                              eligibleActions: ["retarget", "dismiss"])
            historyItems = []
            expectedAction = .retarget
            canDismiss = true
            expectedStatus = nil
            expectedText = ["This conversation expired after 30 minutes. The run waits for you until you dismiss it or send a new message.",
                            "Your next message starts a new conversation."]
            expectedPlaceholder = "Message the orchestrator"
            designFile = "v2/scripts/states-run-questions.js"
        case "dismissing":
            status = try WorkflowSteeringTestFixtures.status(state: "dismiss_pending_settlement", held: true,
                                                              eligibleActions: ["dismiss"])
            historyItems = []
            expectedAction = nil
            canDismiss = false
            expectedStatus = "Dismissing — waiting for running work to settle"
            expectedText = ["Messages are unavailable right now."]
            expectedPlaceholder = "Messages are unavailable right now."
            designFile = "v2/scripts/states-run-questions.js"
        case "dismissed":
            status = try WorkflowSteeringTestFixtures.status(state: "dismissed", held: false, eligibleActions: ["open"])
            raw["status"] = .string("paused")
            raw["attention_reason"] = .string(WorkflowSteeringPresentation.parkedReason)
            raw["monitor_controls"] = .object(["resume": .object([
                "allowed": .bool(false), "reason": .string("No qualified actionable checkpoint is available; refresh the workflow.")
            ])])
            historyItems = []
            expectedAction = .open
            canDismiss = false
            expectedStatus = "Conversation dismissed"
            expectedText = ["Resume is unavailable.", "Your next message starts a new conversation."]
            expectedPlaceholder = "Message the orchestrator"
            designFile = "v2/scripts/states-run-questions.js"
        case "refused":
            status = try WorkflowSteeringTestFixtures.status(state: "command_refused", held: true,
                                                              eligibleActions: ["reply", "dismiss"], latestReplyReference: "history:3")
            historyItems = [
                WorkflowSteeringTestFixtures.historyItem(sequence: 2, kind: "requested", action: "open", episodeID: episodeID,
                                                         text: "Run this command"),
                WorkflowSteeringTestFixtures.historyItem(sequence: 3, kind: "final_captured", episodeID: episodeID,
                                                         turnID: turnID, text: "Run this command"),
                WorkflowSteeringTestFixtures.historyItem(sequence: 4, kind: "classified", turnID: turnID,
                                                         outcome: "role_command_invalid")
            ]
            expectedAction = .reply
            canDismiss = true
            expectedStatus = nil
            expectedText = ["The orchestrator couldn't carry out that request. Reply to continue.", "role_command_invalid"]
            expectedPlaceholder = "Reply to the orchestrator"
            designFile = "v2/scripts/states-run-questions.js"
        default:
            throw MatrixError.unknownState(name)
        }
        let history = try WorkflowSteeringTestFixtures.history(rootID: runID, items: historyItems)
        return MatrixScenario(
            run: WorkflowRunModel(raw: raw), status: status, history: history,
            route: "workflow-run/\(scenarioRoute(name))", designFile: designFile,
            expectedAction: expectedAction, canDismiss: canDismiss, opensNeedsYou: opensNeedsYou,
            expectedStatus: expectedStatus, expectedText: expectedText, expectedPlaceholder: expectedPlaceholder,
            resumeReason: raw["monitor_controls"]?["resume"]?["reason"]?.stringValue
        )
    }

    private func scenarioRoute(_ name: String) -> String {
        switch name {
        case "selected": "orchestrator-selected"
        case "question": "orchestrator-steering-unavailable"
        case "waiting": "orchestrator-steering-waiting"
        case "open": "orchestrator-steering-open"
        case "cancelling": "orchestrator-steering-cancelling"
        case "unknown": "orchestrator-steering-unknown"
        case "stale": "orchestrator-steering-stale"
        case "expired": "orchestrator-steering-expired"
        case "dismissing": "orchestrator-steering-dismissing"
        case "dismissed": "orchestrator-steering-dismissed"
        case "refused": "orchestrator-steering-command-refused"
        default: name
        }
    }

    private struct MatrixScenario {
        let run: WorkflowRunModel
        let status: WorkflowSteeringStatus
        let history: WorkflowSteeringHistoryPage
        let route: String
        let designFile: String
        let expectedAction: WorkflowSteeringAction?
        let canDismiss: Bool
        let opensNeedsYou: Bool
        let expectedStatus: String?
        let expectedText: [String]
        let expectedPlaceholder: String
        let resumeReason: String?
    }

    struct MatrixCapture: Sendable {
        let size: CGSize
        let appearance: ColorScheme
    }

    struct MatrixCase: Sendable {
        let state: String
        let capture: MatrixCapture
    }

    private enum MatrixError: Error { case unknownState(String) }
    // swiftlint:enable function_body_length
}
