import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - WorkflowMessageTruthTests

/// Workflow composers preserve their target and honor exact phase and runtime admission. An unsupported runtime
/// locks node panes instead of failing only after the user presses Send.
@MainActor
@Suite struct WorkflowMessageTruthTests {
    typealias Box = ParallelVMTests.Box
    let rootID = String(repeating: "a", count: 32)
    let childID = String(repeating: "b", count: 32)

    struct Harness {
        let vm: WorkflowVM
        let useCase: MockWorkflowUseCase
        let support: MockWorkflowMessagingSupport
        let context: Box<MessagingInvocationContext?>
        let supported: Box<Bool?>
        let current: Box<Bool>
        let sendFailure: Box<(any Error)?>
        let status: Box<[String: JSONValue]>
        let parallel: ParallelVMTests.SUT
    }

    func makeContext() -> MessagingInvocationContext {
        MessagingInvocationContext(runtime: QualificationRuntimeToken(client: CtlClient(executable: "/fixture/ctl", environment: [:])),
                                   runtimeEpoch: UUID())
    }

    func makeHarness(supported: Bool? = true) -> Harness {
        let useCase = MockWorkflowUseCase()
        let support = MockWorkflowMessagingSupport()
        let context = Box<MessagingInvocationContext?>(makeContext())
        let supportedBox = Box<Bool?>(supported)
        let current = Box(true)
        let sendFailure = Box<(any Error)?>(nil)
        let status = Box<[String: JSONValue]>([:])
        useCase.stubBackendCatalog()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        given(useCase).validate(definition: .any).willReturn(["valid": .bool(true)])
        given(useCase).backendIDs.willReturn(["codex", "claude"])
        given(useCase).modelOptions(backend: .any).willReturn([])
        given(useCase).agentUsageSnapshot.willReturn(.init())
        given(useCase).agentUsagePublisher().willReturn(Just(.init()).eraseToAnyPublisher())
        given(useCase).recordAgentUsage(.any, acknowledgementID: .any).willReturn()
        given(useCase).refreshTasks().willReturn()
        given(useCase).activityRuntime().willReturn(QualificationRuntimeToken(client: CtlClient(executable: "/fixture/ctl", environment: [:])))
        given(useCase).command(.any, options: .any, positionals: .any, runtime: .any).willProduce { command, _, _, _ in
            if command == "send", let failure = sendFailure.value { throw failure }
            if command == "send" { return ["status": .string("queued"), "message_id": .string("message-one")] }
            return status.value
        }
        given(support).messagingInvocationContext().willProduce {
            guard let value = context.value else { throw MessagingAdmissionError.runtimeChanged }
            return value
        }
        given(support).isMessagingContextCurrent(.any).willProduce { _ in current.value }
        given(support).messagingSupport(context: .any).willProduce { _ in supportedBox.value }
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let parallel = ParallelVMTests().makeSUT()
        let vm = WorkflowVM(useCase: useCase, routing: MockWorkflowRouting(), parallel: parallel.sut,
                            draftStore: store, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        vm.messagingSupport = support
        return Harness(vm: vm, useCase: useCase, support: support, context: context, supported: supportedBox, current: current,
                       sendFailure: sendFailure, status: status, parallel: parallel)
    }

    func run(status: String, kind: String = "workflow", taskID: String? = "current-task") -> [String: JSONValue] {
        let activation: [String: JSONValue] = ["id": .string("issued-execution"), "node_id": .string("work"),
            "role": .string("node"), "status": .string("running"), "tasks": .array(taskID.map { [.object([
                "task_id": .string($0), "status": .string("running")])] } ?? [])]
        return ["workflow_run_id": .string(rootID), "status": .string(status), "kind": .string(kind),
            "definition": .object(["nodes": .array([.object(["id": .string("work"), "type": .string("agent")])])]),
            "activations": .array([.object(activation)])]
    }

    // MARK: - Cancelled-run lock

    @Test(arguments: [
        ("cancelled", "workflow", true), ("cancelled", "builder", true),
        ("completed", "workflow", true), ("completed", "builder", false),
        ("cancelling", "workflow", true), ("cancelling", "builder", false),
        ("failed", "workflow", false), ("running", "workflow", false), ("paused", "workflow", false)
    ])
    func givenARun_whenItIsSelected_thenOnlyApprovedPhasesLockItsLanes(status: String, kind: String, locked: Bool) {
        // given
        let harness = makeHarness()
        defer { harness.vm.didDisappear() }

        // when
        harness.vm.selectedRun = WorkflowRunModel(raw: run(status: status, kind: kind))

        // then
        #expect(harness.vm.parallel.isRunMessageLocked == locked)
    }

    @Test func givenARunThatSettles_whenItGoesRunningThenCancellingThenCancelled_thenTheLockAppearsOnlyAtTheLastStep() {
        // given
        let harness = makeHarness()
        defer { harness.vm.didDisappear() }
        harness.vm.selectedRun = WorkflowRunModel(raw: run(status: "running"))
        var locks = [harness.vm.parallel.isRunMessageLocked]

        // when
        for status in ["cancelling", "cancelled"] {
            harness.vm.selectedRun = WorkflowRunModel(raw: run(status: status))
            locks.append(harness.vm.parallel.isRunMessageLocked)
        }

        // then
        #expect(locks == [false, true, true])
    }

    @Test func givenSwitchingBetweenRuns_whenTheSelectionChanges_thenTheLockIsRecomputed() {
        // given
        let harness = makeHarness()
        defer { harness.vm.didDisappear() }
        var child = run(status: "cancelled")
        child["workflow_run_id"] = .string(childID)

        // when / then
        harness.vm.selectedRun = WorkflowRunModel(raw: child)
        #expect(harness.vm.parallel.isRunMessageLocked)
        harness.vm.selectedRun = WorkflowRunModel(raw: run(status: "running"))
        #expect(!harness.vm.parallel.isRunMessageLocked)
        harness.vm.selectedRun = WorkflowRunModel(raw: run(status: "cancelled"))
        #expect(harness.vm.parallel.isRunMessageLocked)
        harness.vm.selectedRun = nil
        #expect(!harness.vm.parallel.isRunMessageLocked)
    }

    @Test func givenACancelledRun_whenTheViewDisappearsAndReappearsWithoutAChange_thenTheLockIsReapplied() async {
        // given
        let harness = makeHarness()
        let raw = run(status: "cancelled")
        harness.status.value = raw
        harness.vm.selectedRun = WorkflowRunModel(raw: raw)
        harness.vm.didAppear()
        #expect(harness.vm.parallel.isRunMessageLocked)

        // when
        harness.vm.didDisappear()
        #expect(!harness.vm.parallel.isRunMessageLocked)
        harness.vm.didAppear()
        defer { harness.vm.didDisappear() }

        // then
        #expect(harness.vm.parallel.isRunMessageLocked)
    }

    // MARK: - Messaging support

    @Test func givenTheViewAppears_whenTheRuntimeSupportsMessaging_thenSupportIsKnownAndNothingLocks() async {
        // given
        let harness = makeHarness(supported: true)

        // when
        harness.vm.didAppear()
        defer { harness.vm.didDisappear() }
        await waitUntil { harness.vm.messagingSupported == true }

        // then
        #expect(!harness.vm.messagingUnsupported)
    }

    @Test func givenTheViewAppears_whenTheRuntimeLacksMessaging_thenTheStateIsUnsupported() async {
        // given
        let harness = makeHarness(supported: false)

        // when
        harness.vm.didAppear()
        defer { harness.vm.didDisappear() }
        await waitUntil { harness.vm.messagingSupported == false }

        // then
        #expect(harness.vm.messagingUnsupported)
    }

    @Test func givenAnUnreadableSupport_whenTheViewAppears_thenTheStateStaysUnknownAndSendingStaysEnabled() async {
        // given
        let harness = makeHarness(supported: nil)
        let raw = run(status: "running")
        harness.status.value = raw
        harness.vm.selectedRun = WorkflowRunModel(raw: raw)
        harness.vm.selectedNodeID = "work"

        // when
        harness.vm.didAppear()
        defer { harness.vm.didDisappear() }
        await waitUntil {
            harness.vm.sidebarTask == nil && harness.vm.activityMessageTarget.taskID == "current-task"
        }
        await verify(harness.support).messagingSupport(context: .any).calledEventually(1, before: .seconds(5))

        // then
        #expect(harness.vm.messagingSupported == nil)
        #expect(!harness.vm.messagingUnsupported)
        #expect(harness.vm.submitActivityMessage("still allowed", now: false))
    }

    @Test func givenAStaleContext_whenTheProbeAnswers_thenTheAnswerIsDiscarded() async {
        // given
        let harness = makeHarness(supported: false)
        harness.current.value = false

        // when
        harness.vm.didAppear()
        defer { harness.vm.didDisappear() }
        await verify(harness.support).messagingSupport(context: .any).calledEventually(1, before: .seconds(5))
        await harness.vm.messagingSupportRead?.value

        // then
        #expect(harness.vm.messagingSupported == nil)
    }

    @Test func givenARuntimeChange_whenTheNextPassPreparesSupport_thenTheOldAnswerIsInvalidatedAndReprobed() async {
        // given
        let harness = makeHarness(supported: false)
        harness.vm.didAppear()
        defer { harness.vm.didDisappear() }
        await waitUntil { harness.vm.messagingSupported == false }

        // when
        harness.context.value = makeContext()
        harness.supported.value = true
        harness.vm.prepareMessagingSupport()

        // then
        #expect(harness.vm.messagingSupported == nil)
        await waitUntil { harness.vm.messagingSupported == true }
        #expect(!harness.vm.messagingUnsupported)
    }

    @Test func givenNoInvocationContext_whenSupportIsPrepared_thenTheStateIsUnknown() async {
        // given
        let harness = makeHarness(supported: false)
        harness.vm.didAppear()
        defer { harness.vm.didDisappear() }
        await waitUntil { harness.vm.messagingSupported == false }

        // when
        harness.context.value = nil
        harness.vm.prepareMessagingSupport()

        // then
        #expect(harness.vm.messagingSupported == nil)
    }

    @Test func givenAnUnsupportedAnswer_whenTheViewDisappears_thenTheStateIsInvalidated() async {
        // given
        let harness = makeHarness(supported: false)
        harness.vm.didAppear()
        await waitUntil { harness.vm.messagingSupported == false }

        // when
        harness.vm.didDisappear()

        // then
        #expect(harness.vm.messagingSupported == nil)
    }

    @Test func givenAnUnknownState_whenASendIsRefusedForTheMissingCapability_thenTheStateFlipsToUnsupported() async {
        // given
        let harness = makeHarness(supported: nil)
        harness.vm.didAppear()
        defer { harness.vm.didDisappear() }
        harness.vm.selectedRun = WorkflowRunModel(raw: run(status: "running"))
        harness.vm.selectedNodeID = "work"
        await waitUntil { harness.vm.activityMessageTarget.taskID == "current-task" }
        harness.sendFailure.value = ToolError.unsupportedCommand(tool: "harflow-ctl", command: "workflow-send",
                                                                 detail: "Missing capability messaging.v1")

        // when
        #expect(harness.vm.submitActivityMessage("try it", now: false))
        await waitUntil { harness.vm.messagingSupported == false }

        // then
        #expect(harness.vm.messagingUnsupported)
        #expect(!harness.vm.submitActivityMessage("blocked now", now: false))
    }

    @Test func givenAnotherSendFailure_whenItIsNotTheCapability_thenTheStateIsUntouched() async {
        // given
        let harness = makeHarness(supported: nil)
        harness.vm.didAppear()
        defer { harness.vm.didDisappear() }
        harness.vm.selectedRun = WorkflowRunModel(raw: run(status: "running"))
        harness.vm.selectedNodeID = "work"
        await waitUntil { harness.vm.activityMessageTarget.taskID == "current-task" }
        harness.sendFailure.value = ToolError.unreadable(tool: "harflow-ctl", exitCode: 1, stderr: "boom")

        // when
        #expect(harness.vm.submitActivityMessage("try it", now: false))
        await waitUntil { !harness.vm.isBusy && harness.vm.errorText != nil }

        // then
        #expect(harness.vm.messagingSupported == nil)
    }

    @Test func givenAnInspectorCreatedBeforeTheProbeResolves_whenTheRuntimeTurnsUnsupported_thenItsComposerLocks() async throws {
        // given — support is unknown while the node's inspector VM is created
        let harness = makeHarness(supported: nil)
        let raw = run(status: "running")
        harness.status.value = raw
        harness.vm.selectedRun = WorkflowRunModel(raw: raw)
        harness.vm.selectedNodeID = "work"
        harness.vm.didAppear()
        defer { harness.vm.didDisappear() }
        await waitUntil { harness.vm.selectedActivity != nil }
        let selected = try #require(harness.vm.selectedActivity)
        let cached = try #require(harness.vm.activityCache.values.first)
        let spare = harness.vm.parallel.makeWorkflowActivity()
        spare.workflowMessageScope = WorkflowMessageScope(
            runID: rootID, nodeID: "work", activationID: "issued-execution", role: .node
        )
        harness.vm.activityCache["spare"] = spare
        harness.vm.applyRunMessageLock()
        #expect(!selected.isMessagingUnsupported && !cached.isMessagingUnsupported && !spare.isMessagingUnsupported)

        // when — the probe answers later
        harness.context.value = makeContext()
        harness.supported.value = false
        harness.vm.prepareMessagingSupport()
        await waitUntil { harness.vm.messagingSupported == false }

        // then
        #expect(selected.isMessagingUnsupported)
        #expect(cached.isMessagingUnsupported)
        #expect(spare.isMessagingUnsupported)
    }

    @Test func givenAnUnsupportedRuntime_whenAnInspectorIsCreatedForANode_thenItStartsLocked() async {
        // given
        let harness = makeHarness(supported: false)
        let raw = run(status: "running")
        harness.status.value = raw
        harness.vm.didAppear()
        defer { harness.vm.didDisappear() }
        await waitUntil { harness.vm.messagingSupported == false }

        // when
        harness.vm.selectedRun = WorkflowRunModel(raw: raw)
        harness.vm.selectedNodeID = "work"
        await waitUntil { harness.vm.selectedActivity != nil }

        // then
        #expect(harness.vm.selectedActivity?.isMessagingUnsupported == true)
    }

    @Test(arguments: [false, true])
    func givenCapturedSendFeedback_whenTheRuntimeOrAppearanceChanges_thenItsUnsupportedFailureIsDiscarded(reappear: Bool) async {
        // given
        let harness = makeHarness(supported: nil)
        harness.status.value = run(status: "running")
        harness.vm.selectedRun = WorkflowRunModel(raw: harness.status.value)
        harness.vm.selectedNodeID = "work"
        harness.vm.didAppear()
        defer { harness.vm.didDisappear() }
        await waitUntil { harness.vm.activityMessageTarget.taskID == "current-task" }
        let onFailure = harness.vm.makeMessagingFailureHandler()
        let failure = ToolError.unsupportedCommand(tool: "harflow-ctl", command: "workflow-send", detail: "Missing capability messaging.v1")

        // when
        harness.supported.value = true
        if reappear {
            harness.vm.didDisappear()
            harness.vm.didAppear()
        } else {
            harness.context.value = makeContext()
            harness.vm.prepareMessagingSupport()
        }
        await waitUntil { harness.vm.messagingSupported == true }
        onFailure(failure)

        // then
        #expect(harness.vm.messagingSupported == true)
        #expect(!harness.vm.messagingUnsupported)
    }

    @Test func givenAnUnknownProbe_whenTheInspectorSendReportsUnsupported_thenEveryCachedInspectorLocks() async throws {
        // given
        let harness = makeHarness(supported: nil)
        let raw = run(status: "running")
        harness.status.value = raw
        harness.vm.selectedRun = WorkflowRunModel(raw: raw)
        harness.vm.selectedNodeID = "work"
        harness.vm.didAppear()
        defer { harness.vm.didDisappear() }
        await waitUntil { harness.vm.selectedActivity != nil }
        let inspector = try #require(harness.vm.selectedActivity)
        let node = ParallelVMTests().task(id: "current-task")
        harness.parallel.tasksBox.value[node.taskID] = node
        given(harness.parallel.useCase).sendMessage(.any, text: .any, now: .any).willThrow(
            ToolError.unsupportedCommand(tool: "harflow-ctl", command: "send", detail: "Missing capability messaging.v1"))
        inspector.didAppear()
        harness.parallel.tasksSubject.send([node])
        await waitUntil { inspector.columns.count == 1 && inspector.isPresentationSettled }
        let column = try #require(inspector.columns.first)
        #expect(!inspector.isMessagingUnsupported)

        // when
        #expect(column.onSubmitMessage?("probe by sending", false) == true)
        await waitUntil { harness.vm.messagingUnsupported }

        // then
        #expect(inspector.isMessagingUnsupported)
        let allInspectorsLocked = harness.vm.activityCache.values.allSatisfy(\.isMessagingUnsupported)
        #expect(allInspectorsLocked)
        #expect(inspector.columns.first?.onSubmitMessage?("blocked", false) == false)
    }

    // MARK: - Composer models

    @Test func givenAnUnsupportedRuntime_whenTheFallbackComposerIsBuilt_thenItHasNoPlaceholderHintOrSendNow() {
        // given
        let target = WorkflowActivityMessageTarget(runID: rootID, taskID: "node", unavailableReason: nil)

        // when
        let model = WorkflowActivityMessageComposer<WorkflowVM>.boxModel(target: target, unsupported: true, isBusy: false)

        // then
        #expect(model.isLocked)
        #expect(!model.canSend)
        #expect(model.placeholder.isEmpty)
        #expect(model.hint.isEmpty)
        #expect(!model.showsSendNow)
    }

    @Test func givenAnUnavailableTarget_whenTheRuntimeIsUnsupported_thenTheExistingReasonKeepsPrecedence() {
        // given
        let target = WorkflowActivityMessageTarget(runID: nil, taskID: nil, unavailableReason: "Not called yet.")

        // when
        let model = WorkflowActivityMessageComposer<WorkflowVM>.boxModel(target: target, unsupported: true, isBusy: false)

        // then
        #expect(model.isLocked)
        #expect(model.placeholder == "Not called yet.")
        #expect(model.showsSendNow)
    }

    @Test func givenASupportedRuntime_whenTheFallbackComposerIsBuilt_thenItIsUnchanged() {
        // given
        let target = WorkflowActivityMessageTarget(runID: rootID, taskID: "node", unavailableReason: nil)

        // when
        let model = WorkflowActivityMessageComposer<WorkflowVM>.boxModel(target: target, unsupported: false, isBusy: false)

        // then
        #expect(!model.isLocked)
        #expect(model.canSend)
        #expect(model.placeholder == "Queue a message…")
        #expect(model.hint == "Send queues; Send now requests immediate delivery when safe")
        #expect(model.showsSendNow)
    }

    private func column(takenOver: Bool = false, lock: ParallelMessageLock?, chrome: ParallelColumnChrome) throws -> ParallelColumnModel {
        var raw: [String: JSONValue] = ["task_id": .string("lane"), "backend": .string("claude"), "status": .string("cancelled")]
        if takenOver { raw["taken_over"] = .bool(true) }
        let task = try #require(TaskInfo(.object(raw)))
        var column = ParallelColumnModel(id: "lane", task: task, title: "Lane", subtitle: "", isBusy: false, outcomeMessage: nil,
                                         showPrompt: false, rows: [], activityRows: [], isLoading: false, summary: nil,
                                         onTapOpenTask: {})
        column.chrome = chrome
        column.messageLock = lock
        column.onSubmitMessage = { _, _ in true }
        return column
    }

    @Test func givenACancelledRunLane_whenItsComposerIsBuilt_thenItLocksWithTheApprovedCopy() throws {
        // given
        let model = try column(lock: .runCancelled, chrome: .lane).laneMessageBoxModel

        // then
        #expect(model.isLocked)
        #expect(!model.canSend)
        #expect(model.placeholder == "Messages are off — this run was cancelled")
    }

    @Test func givenATakenOverLaneOfACancelledRun_whenItsComposerIsBuilt_thenTakeoverKeepsItsOwnCopy() throws {
        // given
        let model = try column(takenOver: true, lock: .runCancelled, chrome: .lane).laneMessageBoxModel

        // then
        #expect(model.isLocked)
        #expect(model.placeholder == MessageBoxDisabledReason.takenOver.text)
    }

    @Test func givenAnOrdinaryLane_whenItsComposerIsBuilt_thenItStaysOpen() throws {
        // given
        let model = try column(lock: nil, chrome: .lane).laneMessageBoxModel

        // then
        #expect(!model.isLocked)
        #expect(model.canSend)
        #expect(model.placeholder == "Message Claude")
    }

    @Test func givenAnUnsupportedInspector_whenItsComposerIsBuilt_thenItLocksBareWithoutSendNow() throws {
        // given
        let model = try column(lock: .messagingUnsupported, chrome: .inspector).inspectorMessageBoxModel

        // then
        #expect(model.isLocked)
        #expect(!model.canSend)
        #expect(model.placeholder.isEmpty)
        #expect(model.hint.isEmpty)
        #expect(!model.showsSendNow)
    }

    @Test func givenAnUnsupportedWorkflowLane_whenItsComposerIsBuilt_thenItLocks() throws {
        // given
        let model = try column(lock: .messagingUnsupported, chrome: .lane).laneMessageBoxModel

        // then
        #expect(model.isLocked)
        #expect(!model.canSend)
    }

    @Test func givenATakenOverUnsupportedInspector_whenItsComposerIsBuilt_thenTakeoverKeepsItsCopy() throws {
        // given
        let model = try column(takenOver: true, lock: .messagingUnsupported, chrome: .inspector).inspectorMessageBoxModel

        // then
        #expect(model.isLocked)
        #expect(model.placeholder == MessageBoxDisabledReason.takenOver.text)
        #expect(model.showsSendNow)
    }

    // MARK: - Undeliverable bubbles

    private func messages(_ entries: [(id: String, seq: Int, status: String, reason: String?)]) -> [String: JSONValue] {
        ["task_id": .string("lane"), "workflow_run_id": .string(rootID), "messages": .array(entries.map { entry in
            var object: [String: JSONValue] = ["id": .string(entry.id), "seq": .number(Double(entry.seq)),
                "status": .string(entry.status), "text": .string("text \(entry.id)")]
            if let reason = entry.reason { object["reason"] = .string(reason) }
            return .object(object)
        })]
    }

    @Test func givenALaneWithAnUndeliverableMessage_whenProjected_thenTheBubbleCarriesTheReasonAndNoCancel() {
        // given
        let raw = messages([("gone", 1, "undeliverable", "The workflow run was cancelled.")])

        // when
        let bubbles = WorkMessageBubble.project(raw: raw)

        // then
        #expect(bubbles.count == 1)
        #expect(bubbles.first?.kind == .undeliverable("The workflow run was cancelled."))
        #expect(bubbles.first?.caption == "Undeliverable")
        #expect(bubbles.first?.note == "The workflow run was cancelled.")
        #expect(bubbles.first?.canCancel == false)
        #expect(bubbles.first?.isPinned == false)
    }

    @Test func givenAQueuedAndAnUndeliverableMessage_whenProjected_thenOnlyTheQueuedOneKeepsCancel() {
        // given
        let raw = messages([("waiting", 1, "queued", nil), ("gone", 2, "undeliverable", "The run ended.")])

        // when
        let bubbles = WorkMessageBubble.project(raw: raw)

        // then
        #expect(bubbles.map(\.id) == ["waiting", "gone"])
        #expect(bubbles.map(\.canCancel) == [true, false])
    }

    @Test func givenALockedLane_whenItHoldsAQueuedBubble_thenTheComposerLockLeavesTheBubbleCancellable() throws {
        // given
        var locked = try column(lock: .runCancelled, chrome: .lane)
        locked.workMessages = WorkMessageBubble.project(raw: messages([("waiting", 1, "queued", nil)]))

        // then
        #expect(locked.laneMessageBoxModel.isLocked)
        #expect(locked.workMessages.first?.canCancel == true)
    }
}
