import AppKit
import Combine
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import SwiftEnvironment
import SwiftUI
import Testing

// MARK: - WorkflowSteeringHostedTests

@MainActor @Suite(.serialized)
struct WorkflowSteeringHostedTests {
    let rootID = WorkflowSteeringTestFixtures.rootRunID
    private let episodeID = WorkflowSteeringTestFixtures.episodeID
    private let turnID = WorkflowSteeringTestFixtures.turnID

    // Keep the terminal fixture and its evidence assertion together to preserve the capture's exact setup.
    // swiftlint:disable function_body_length
    @Test(arguments: [CGSize(width: 1000, height: 620), CGSize(width: 1440, height: 900)], [ColorScheme.light, .dark])
    func givenCancelledSelectedOrchestratorWithEarlierConversation_whenHosted_thenLockCopyAndConversationStayInOrder(
        size: CGSize, appearance: ColorScheme
    ) async throws {
        let status = try WorkflowSteeringTestFixtures.status(state: "dismissed", held: false, eligibleActions: ["open"])
        let history = try WorkflowSteeringTestFixtures.history(rootID: rootID, items: [
            WorkflowSteeringTestFixtures.historyItem(sequence: 2, kind: "requested", action: "open", episodeID: episodeID,
                                                     text: "Earlier caller message"),
            WorkflowSteeringTestFixtures.historyItem(sequence: 3, kind: "final_captured", episodeID: episodeID,
                                                     turnID: turnID, text: "Earlier orchestrator reply"),
            WorkflowSteeringTestFixtures.historyItem(sequence: 4, kind: "classified", turnID: turnID, outcome: "conversation")
        ])
        let endpoint = try WorkflowSteeringHostedEndpoint(rootID: rootID, status: status, history: history)
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: endpoint)
        let runtimeSelection = SteeringHostedRuntimeSelection(client: client)
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willProduce { .success(runtimeSelection.client) }
        let repository = WorkflowSteeringRepositoryImpl(tooling: tooling)
        let (vm, _, _, _) = makeSteeringVM(repository: repository, runtimeSelection: runtimeSelection)
        let raw = cancelledRoot()
        vm.selectedRun = WorkflowRunModel(raw: raw)
        vm.selectedNodeID = WorkflowStandalone.orchestratorID
        vm.primaryNodeID = WorkflowStandalone.orchestratorID
        vm.selectedNodeIDs = [WorkflowStandalone.orchestratorID]
        vm.runSidebar = WorkflowRunSidebarPresentation.build(run: raw, nodeID: WorkflowStandalone.orchestratorID, attemptID: nil)
        vm.didSubscribe = true
        let scratch = ScratchDefaults(label: "stage3-steering-cancelled-\(UUID().uuidString)")
        scratch.defaults.set("Graph", forKey: "workflowViewMode")
        defer { scratch.remove(); vm.didDisappear() }
        let fixture = RedesignHost(
            WorkflowView(vm).defaultAppStorage(scratch.defaults).preferredColorScheme(appearance),
            size: size, appearance: appearance
        )
        defer { fixture.close() }
        fixture.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await fixture.settle { fixture.element("workflow-steering-panel") != nil }
        vm.startSteeringObservation()
        await fixture.settle { fixture.element("workflow-steering-status") != nil && fixture.element("You: Earlier caller message") != nil }

        // then
        #expect(fixture.element("workflow-steering-panel") != nil)
        #expect(fixture.element("workflow-steering-dismiss") == nil, "A terminal conversation with no current hold has no Dismiss action")
        #expect(fixture.element("workflow-steering-composer") != nil)
        #expect(fixture.element("The run was cancelled.") != nil)
        #expect(fixture.element("You: Earlier caller message") != nil)
        #expect(fixture.element("Orchestrator: Earlier orchestrator reply") != nil)
        #expect(fixture.element("Not started") == nil, "The attributable conversation replaces only the legacy empty state")
        let send = try #require(fixture.element("Send"))
        #expect(TaskStoppingHostedTests.isEnabled(send) == false)

        let statusElement = try #require(fixture.element("workflow-steering-status"))
        let callerElement = try #require(fixture.element("You: Earlier caller message"))
        let statusFrame = try #require(fixture.frame(statusElement))
        let callerFrame = try #require(fixture.frame(callerElement))
        #expect(statusFrame.minY > callerFrame.maxY, "The cancelled status stays ahead of the earlier conversation")

        if let directory = HostedCaptureEvidence.directory("HARFLOW_STAGE3_STEERING_CAPTURE_DIR") {
            await HostedCaptureEvidence.prepare(fixture.window, dark: appearance == .dark)
            try await HostedCaptureEvidence.record(
                directory: directory,
                subject: .init(
                    suite: "WorkflowSteeringHostedTests", state: "cancelled-orchestrator-locked",
                    dark: appearance == .dark, size: NSSize(width: size.width, height: size.height),
                    design: .init(
                        route: "workflow-run/cancelled-orchestrator-locked",
                        file: "v2/scripts/states-run-questions.js",
                        commit: "70d94ef16173b7f48bc72d4930949f3df0b0b7cd"
                    )
                ),
                window: fixture.window, host: fixture.host
            )
        }
    }

    // swiftlint:enable function_body_length

    // The key-loop, two real submissions, and Escape draft check share one live AppKit field lifecycle.
    // swiftlint:disable function_body_length
    @Test func givenReplyComposer_whenTabReturnAndEscapeAreDelivered_thenNativeControlsAndDraftRemainUsable() async throws {
        // given
        let endpoint = try WorkflowSteeringHostedEndpoint(rootID: rootID)
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: endpoint)
        let runtimeSelection = SteeringHostedRuntimeSelection(client: client)
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willProduce { .success(runtimeSelection.client) }
        let repository = WorkflowSteeringRepositoryImpl(tooling: tooling)
        let (vm, _, _, _) = makeSteeringVM(repository: repository, runtimeSelection: runtimeSelection)
        let raw = runningRoot()
        vm.selectedRun = WorkflowRunModel(raw: raw)
        vm.primaryNodeID = WorkflowStandalone.orchestratorID
        vm.selectedNodeIDs = [WorkflowStandalone.orchestratorID]
        vm.runSidebar = WorkflowRunSidebarPresentation.build(run: raw, nodeID: WorkflowStandalone.orchestratorID, attemptID: nil)
        vm.didSubscribe = true
        vm.startSteeringObservation()
        await waitUntil { vm.steering.action == .reply && vm.steeringAuthority != nil }
        let staleAuthority = try #require(vm.steeringAuthority)
        try endpoint.advanceStatus(sequence: 11)
        await endpoint.blockNextHistoryPage()
        await vm.steeringReadTask?.value
        vm.requestSteeringRead()
        await endpoint.waitForHistoryRequest()
        vm.submitSteering("Stale rendered reply", authority: staleAuthority)
        await Task.yield()
        #expect(endpoint.actions.isEmpty, "A displayed authority is revoked as soon as a newer status read begins")
        await endpoint.releaseHistoryPage()
        await vm.steeringReadTask?.value
        await waitUntil { vm.steeringObservation?.status.sequence == 11 && vm.steeringAuthority != staleAuthority }
        let fixture = RedesignHost(WorkflowSteeringPanel(viewModel: vm), size: CGSize(width: 720, height: 240))
        defer { vm.didDisappear(); fixture.close() }
        fixture.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await fixture.settle { fixture.element("workflow-steering-dismiss") != nil && field(in: fixture) != nil }
        let editorField = try #require(field(in: fixture))

        // when: follow the native reverse chain to the SwiftUI Dismiss accessibility control, then Tab back to the field.
        #expect(fixture.window.makeFirstResponder(editorField))
        fixture.window.sendEvent(try keyEvent("\t", keyCode: 48, modifiers: .shift, window: fixture.window))
        await fixture.settle { focusedDismiss() }
        #expect(focusedDismiss(), "Reverse native Tab reaches the exact Dismiss accessibility control")
        let dismissResponder = try #require(fixture.window.firstResponder as? NSView)
        #expect(dismissResponder.window === fixture.window)
        #expect(keyViewLoopReaches(editorField, from: dismissResponder, in: fixture, forward: true)
                || keyViewLoopReaches(editorField, from: dismissResponder, in: fixture, forward: false))
        fixture.window.sendEvent(try keyEvent("\t", keyCode: 48, window: fixture.window))
        await fixture.settle { fixture.window.firstResponder === editorField || editorField.currentEditor() != nil }
        #expect(fixture.window.firstResponder === editorField || editorField.currentEditor() != nil)

        await MessageBoxTranscriptStyleHostedTests.type("Caller draft", into: editorField, in: fixture)
        let returnEvent = try keyEvent("\r", keyCode: 36, window: fixture.window)
        fixture.window.sendEvent(returnEvent)
        await waitUntil { endpoint.actions == ["reply"] && vm.steeringDraft.isEmpty }
        #expect(endpoint.texts == ["Caller draft"], "Plain Return follows the existing MessageBox submission path")

        await fixture.settle { vm.steering.action == .reply && vm.steeringAuthority != nil && field(in: fixture) != nil }
        let commandEditor = try #require(field(in: fixture))
        #expect(fixture.window.makeFirstResponder(commandEditor))
        await MessageBoxTranscriptStyleHostedTests.type("Command draft", into: commandEditor, in: fixture)
        #expect(vm.steeringDraft == "Command draft")
        let commandReturn = try keyEvent("\r", keyCode: 36, modifiers: .command, window: fixture.window)
        #expect(fixture.window.performKeyEquivalent(with: commandReturn))
        await waitUntil { endpoint.actions == ["reply", "reply"] && vm.steeringDraft.isEmpty }
        #expect(endpoint.texts == ["Caller draft", "Command draft"], "The focused command submits the exact draft through the public adapter")
        #expect(vm.steeringDraft.isEmpty, "The accepted receipt clears the captured draft")

        await fixture.settle { vm.steering.action == .reply && vm.steeringAuthority != nil && field(in: fixture) != nil }
        let escapeEditor = try #require(field(in: fixture))
        #expect(fixture.window.makeFirstResponder(escapeEditor))
        await MessageBoxTranscriptStyleHostedTests.type("Retained draft", into: escapeEditor, in: fixture)
        fixture.window.sendEvent(try keyEvent("\u{1b}", keyCode: 53, window: fixture.window))
        await Task.yield()

        // then
        #expect(fixture.element("workflow-steering-panel") != nil)
        #expect(vm.steeringDraft == "Retained draft", "Escape preserves the unsent draft")
        #expect(endpoint.actions == ["reply", "reply"], "Escape does not issue a steering action")
    }

    // swiftlint:enable function_body_length

    // This verifies that a status refresh preserves a live AppKit editor while withholding old authority.
    @Test func givenIrrelevantRunUpdateDuringReply_whenHistoryRevalidates_thenFieldAndDraftStayFocusedUntilFreshAuthority() async throws {
        let endpoint = try WorkflowSteeringHostedEndpoint(rootID: rootID)
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: endpoint)
        let runtimeSelection = SteeringHostedRuntimeSelection(client: client)
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willProduce { .success(runtimeSelection.client) }
        let repository = WorkflowSteeringRepositoryImpl(tooling: tooling)
        let (vm, _, _, _) = makeSteeringVM(repository: repository, runtimeSelection: runtimeSelection)
        defer { vm.didDisappear(); Task { await endpoint.releaseHistoryPage() } }
        let raw = runningRoot()
        vm.selectedRun = WorkflowRunModel(raw: raw)
        vm.primaryNodeID = WorkflowStandalone.orchestratorID
        vm.didSubscribe = true
        vm.startSteeringObservation()
        await waitUntil { vm.steering.action == .reply && vm.steeringAuthority != nil }

        let fixture = RedesignHost(WorkflowSteeringPanel(viewModel: vm), size: CGSize(width: 720, height: 240))
        defer { fixture.close() }
        fixture.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await fixture.settle { field(in: fixture) != nil }
        let initialField = try #require(field(in: fixture))
        #expect(fixture.window.makeFirstResponder(initialField))
        await MessageBoxTranscriptStyleHostedTests.type("Preserve me while checking status", into: initialField, in: fixture)
        #expect(vm.steeringDraft == "Preserve me while checking status")
        let oldAuthority = try #require(vm.steeringAuthority)
        let initialResponder = try #require(fixture.window.firstResponder as? NSView)

        await endpoint.blockNextHistoryPage()
        let priorHistoryRequests = endpoint.historyRequests
        try endpoint.advanceStatus(sequence: 11)
        var updatedRaw = raw
        updatedRaw["updated_at"] = .string("metadata-only-change")
        vm.selectedRun = WorkflowRunModel(raw: updatedRaw)
        vm.requestSteeringRead()
        await waitUntil(timeout: 5) { endpoint.historyRequests > priorHistoryRequests }
        guard endpoint.historyRequests > priorHistoryRequests else {
            await endpoint.releaseHistoryPage()
            #expect(endpoint.historyRequests > priorHistoryRequests, "The advanced public status should request its bounded history page")
            return
        }
        await fixture.settle { vm.steeringRevalidating }

        let send = try #require(fixture.element("Send"))
        let dismiss = try #require(fixture.element("workflow-steering-dismiss"))
        #expect(MessageBoxTranscriptStyleHostedTests.editableField(in: fixture) === initialField)
        #expect(fixture.window.firstResponder === initialResponder)
        #expect(vm.steeringDraft == "Preserve me while checking status")
        #expect(TaskStoppingHostedTests.isEnabled(send) == false)
        #expect(TaskStoppingHostedTests.isEnabled(dismiss) == false)
        vm.submitSteering("Stale action during revalidation", authority: oldAuthority)
        await Task.yield()
        #expect(endpoint.actions.isEmpty, "The old rendered token cannot admit while the check is in flight")

        await endpoint.releaseHistoryPage()
        await vm.steeringReadTask?.value
        await fixture.settle { !vm.steeringRevalidating && vm.steeringAuthority != oldAuthority }

        // then
        #expect(MessageBoxTranscriptStyleHostedTests.editableField(in: fixture) === initialField)
        #expect(fixture.window.firstResponder === initialResponder)
        #expect(vm.steeringDraft == "Preserve me while checking status")
        #expect(TaskStoppingHostedTests.isEnabled(try #require(fixture.element("Send"))) == true)
        #expect(TaskStoppingHostedTests.isEnabled(try #require(fixture.element("workflow-steering-dismiss"))) == true)
        #expect(endpoint.actions.isEmpty)
    }

    @Test func givenReplyInFlight_whenRuntimeChangesAtoBtoA_thenDelayedAdmissionDoesNotClearDraft() async throws {
        // given
        let endpoint = try WorkflowSteeringHostedEndpoint(rootID: rootID, blockSteering: true)
        let clientA = CtlClient(executable: "/fixture/ctl", environment: ["FIXTURE_RUNTIME": "A"], runner: endpoint)
        let runtimeSelection = SteeringHostedRuntimeSelection(client: clientA)
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willProduce { .success(runtimeSelection.client) }
        let repository = WorkflowSteeringRepositoryImpl(tooling: tooling)
        let (vm, _, runtimeChanges, _) = makeSteeringVM(repository: repository, runtimeSelection: runtimeSelection)
        defer { vm.didDisappear(); Task { await endpoint.releaseSteeringRequest() } }
        vm.selectedRun = WorkflowRunModel(raw: runningRoot())
        vm.primaryNodeID = WorkflowStandalone.orchestratorID
        vm.selectedNodeIDs = [WorkflowStandalone.orchestratorID]
        vm.runSidebar = WorkflowRunSidebarPresentation.build(run: runningRoot(), nodeID: WorkflowStandalone.orchestratorID, attemptID: nil)
        vm.didSubscribe = true
        vm.startSteeringObservation()
        await waitUntil { vm.steeringAuthority != nil && vm.steering.action == .reply }
        vm.steeringDraft = "Keep after the runtime round trip"

        // when
        vm.submitSteering(vm.steeringDraft, authority: vm.steeringAuthority)
        await endpoint.waitForSteeringRequest()
        let clientB = CtlClient(executable: "/fixture/ctl", environment: ["FIXTURE_RUNTIME": "B"], runner: endpoint)
        runtimeSelection.select(clientB)
        runtimeChanges.send(.installing)
        runtimeSelection.select(clientA)
        runtimeChanges.send(.preparing)
        await endpoint.releaseSteeringRequest()
        await waitUntil { endpoint.actions == ["reply"] && vm.steeringAuthority != nil }

        // then
        #expect(endpoint.texts == ["Keep after the runtime round trip"])
        #expect(vm.steeringDraft == "Keep after the runtime round trip")
    }

    private func cancelledRoot() -> [String: JSONValue] {
        [
            "workflow_run_id": .string(rootID),
            "root_workflow_run_id": .string(rootID),
            "name": .string("Steering fixture"),
            "kind": .string("workflow"),
            "status": .string("cancelled"),
            "definition": .object(["nodes": .array([])]),
            // swiftformat:disable:next trailingCommas
            "activations": .array([])
        ]
    }

    func runningRoot() -> [String: JSONValue] {
        [
            "workflow_run_id": .string(rootID),
            "root_workflow_run_id": .string(rootID),
            "status": .string("running"),
            "kind": .string("workflow"),
            // swiftformat:disable:next trailingCommas
            "activations": .array([])
        ]
    }

    private func field(in fixture: RedesignHost) -> NSTextField? {
        MessageBoxTranscriptStyleHostedTests.editableField(in: fixture)
    }

    private func focusedDismiss() -> Bool {
        let focused = NSApp.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXFocusedUIElement")) as? NSObject
        guard let focused else { return false }
        let selector = NSSelectorFromString("accessibilityIdentifier")
        let identifier = focused.responds(to: selector) ? focused.perform(selector)?.takeUnretainedValue() as? String : nil
        let labelSelector = NSSelectorFromString("accessibilityLabel")
        let label = focused.responds(to: labelSelector) ? focused.perform(labelSelector)?.takeUnretainedValue() as? String : nil
        return identifier == "workflow-steering-dismiss" || label == "Dismiss"
    }

    private func keyViewLoopReaches(_ target: NSView, from anchor: NSView, in fixture: RedesignHost, forward: Bool) -> Bool {
        var visited = Set<ObjectIdentifier>()
        var current: NSView? = anchor
        for _ in 0 ..< 128 {
            guard let view = current, view.window === fixture.window,
                  visited.insert(ObjectIdentifier(view)).inserted else { return false }
            if view === target || (target as? NSTextField)?.currentEditor() === view { return true }
            current = forward ? view.nextValidKeyView : view.previousValidKeyView
        }
        return false
    }

    private func keyEvent(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ))
    }
}

@MainActor
private final class SteeringHostedUseCase: WorkflowUseCase {
    private let base: MockWorkflowUseCase
    private let repository: WorkflowSteeringRepositoryImpl

    init(base: MockWorkflowUseCase, repository: WorkflowSteeringRepositoryImpl) {
        self.base = base
        self.repository = repository
    }

    func steeringObservation(rootID: String) async throws -> WorkflowSteeringObservation {
        try await repository.observation(rootID: rootID)
    }

    func steeringHistory(observation: WorkflowSteeringObservation, cursor: String?) async throws -> WorkflowSteeringHistoryPage {
        try await repository.history(observation: observation, cursor: cursor)
    }

    func performSteering(action: WorkflowSteeringAction, text: String?, observation: WorkflowSteeringObservation) async throws -> WorkflowSteeringAttempt {
        try await repository.perform(action: action, text: text, observation: observation)
    }

    func steeringAttempts(rootID: String) -> [WorkflowSteeringAttempt] { repository.attempts(rootID: rootID) }
    func isSteeringCurrent(_ observation: WorkflowSteeringObservation) -> Bool { repository.isCurrent(observation) }
    func activityRuntime() throws -> QualificationRuntimeToken { try base.activityRuntime() }
    func activity(
        runID: String, executionID: String, intent: WorkflowActivityReadIntent, runtime: QualificationRuntimeToken
    ) async throws -> WorkflowActivityPage {
        try await base.activity(runID: runID, executionID: executionID, intent: intent, runtime: runtime)
    }

    func qualificationSession() -> QualificationSession { base.qualificationSession() }
    func command(_ command: String, options: [String], positionals: [String], runtime: QualificationRuntimeToken?) async throws -> [String: JSONValue] {
        try await base.command(command, options: options, positionals: positionals, runtime: runtime)
    }

    func boundBuilderCommand(_ command: String, options: [String], positionals: [String], runtime: QualificationRuntimeToken,
                             isCurrent: @escaping @Sendable () -> Bool) async throws -> [String: JSONValue] {
        try await base.boundBuilderCommand(command, options: options, positionals: positionals, runtime: runtime, isCurrent: isCurrent)
    }

    func validate(definition: JSONValue) async throws -> [String: JSONValue] { try await base.validate(definition: definition) }
    func save(name: String, definition: JSONValue, expectedRevision: Int, expectedWorkflowID: String?) async throws -> [String: JSONValue] {
        try await base.save(name: name, definition: definition, expectedRevision: expectedRevision, expectedWorkflowID: expectedWorkflowID)
    }

    func artifactPage(runID: String, executionID: String, cursor: String?) async -> Result<WorkflowArtifactPage, ToolError> {
        await base.artifactPage(runID: runID, executionID: executionID, cursor: cursor)
    }

    func refreshTasks() async { await base.refreshTasks() }
    var backendIDs: [String] { base.backendIDs }
    var agentUsageSnapshot: AgentUsageSnapshot { base.agentUsageSnapshot }
    func agentUsagePublisher() -> AnyPublisher<AgentUsageSnapshot, Never> { base.agentUsagePublisher() }
    func recordAgentUsage(_ identity: AgentUsageIdentity, acknowledgementID: String) async {
        await base.recordAgentUsage(identity, acknowledgementID: acknowledgementID)
    }

    var callerApprovalBackends: Set<String> { base.callerApprovalBackends }
    var backendCatalog: BackendCatalog { base.backendCatalog }
    func backendCatalogPublisher() -> AnyPublisher<BackendCatalog, Never> { base.backendCatalogPublisher() }
    func modelOptions(backend: String) async -> [ModelOption] { await base.modelOptions(backend: backend) }
}

@MainActor
func makeSteeringVM(
    repository: WorkflowSteeringRepositoryImpl, runtimeSelection: SteeringHostedRuntimeSelection
) -> (WorkflowVM, MockWorkflowUseCase, CurrentValueSubject<ManagedRuntimeState, Never>, MockWorkflowRouting) {
    let base = MockWorkflowUseCase()
    base.stubBackendCatalog()
    given(base).qualificationSession().willReturn(QualificationSession(repository: QualificationFixture(gated: false)))
    given(base).activityRuntime().willProduce { QualificationRuntimeToken(client: runtimeSelection.client) }
    given(base).validate(definition: .any).willReturn(["valid": .bool(true)])
    given(base).backendIDs.willReturn(["codex", "claude"])
    given(base).agentUsageSnapshot.willReturn(.init())
    given(base).recordAgentUsage(.any, acknowledgementID: .any).willReturn()
    given(base).refreshTasks().willReturn()
    given(base).activity(runID: .any, executionID: .any, intent: .any, runtime: .any).willProduce { runID, executionID, _, _ in
        WorkflowActivityPage(raw: ["workflow_run_id": .string(runID), "execution_id": .string(executionID),
                                   "events": .array([]), "has_more": .bool(false)], runID: runID, executionID: executionID)!
    }
    let routing = MockWorkflowRouting()
    given(routing).chooseDirectory().willReturn(nil)
    given(routing).selectTask(.any).willReturn()
    given(routing).didSaveWorkflow(name: .any).willReturn()
    given(routing).openWorkflowEditor(name: .any).willReturn()
    given(routing).showNeedsYou(itemID: .any).willReturn()
    let useCase = SteeringHostedUseCase(base: base, repository: repository)
    let runtimeChanges = CurrentValueSubject<ManagedRuntimeState, Never>(.preparing)
    repository.bindRuntimeChanges(runtimeChanges.eraseToAnyPublisher())
    let vm = WorkflowVM(useCase: useCase, routing: routing, parallel: ParallelVMTests().makeSUT().sut,
                        draftStore: WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                        visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
    return (vm, base, runtimeChanges, routing)
}

final class SteeringHostedRuntimeSelection: @unchecked Sendable {
    private let lock = NSLock()
    private var selectedClient: CtlClient

    init(client: CtlClient) { self.selectedClient = client }

    var client: CtlClient { lock.withLock { selectedClient } }

    func select(_ client: CtlClient) { lock.withLock { selectedClient = client } }
}
