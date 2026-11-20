import Foundation
@testable import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - TaskDetailSettledMessageTests

extension TaskDetailVMTests {
    @Test(arguments: ["completed", "failed", "cancelled", "timed_out", "running"],
          [TaskDetailChrome.standalone, .group, .embedded, .builder])
    func givenTaskStatus_whenComposerRecomputes_thenSendNowRequiresRunningTask(status: String, chrome: TaskDetailChrome) async {
        // given
        let fixtures = Fixtures()
        fixtures.detailBox.value = task(status: status)
        let runtime = QualificationRuntimeToken(client: CtlClient(executable: "/fixture/ctl", environment: [:]))
        fixtures.continuationRuntime.value = runtime
        fixtures.messagingContext.value = MessagingInvocationContext(runtime: runtime, runtimeEpoch: UUID())
        fixtures.messagingSupported.value = true
        let harness = makeSUT(isWorkflowBuilder: chrome == .builder, chrome: chrome, fixtures: fixtures)
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.task != nil && harness.sut.messagingSupported == true }
        // when
        harness.sut.recomputeMessageBox(task: fixtures.detailBox.value!)
        // then
        #expect(harness.sut.messageBoxModel.canSend)
        #expect(harness.sut.messageBoxModel.showsSendNow == (status == "running"))
        #expect(harness.sut.messageBoxModel.hint == "Send queues; Send now requests immediate delivery when safe")
    }

    @Test(arguments: ["workflow_run_id", "workflow_node_id", "workflow_role"])
    func givenTerminalWorkflowOwnedTaskOnStandaloneMount_whenNowAndQueuedSendCalled_thenOnlyQueuedSendDispatches(identity: String) async throws {
        // given
        let fixtures = Fixtures()
        var raw = task(status: "completed").raw
        raw[identity] = .string(identity == "workflow_role" ? "worker" : "workflow-identity")
        fixtures.detailBox.value = try #require(TaskInfo(.object(raw)))
        let runtime = QualificationRuntimeToken(client: CtlClient(executable: "/fixture/ctl", environment: [:]))
        let context = MessagingInvocationContext(runtime: runtime, runtimeEpoch: UUID())
        fixtures.continuationRuntime.value = runtime
        fixtures.messagingContext.value = context
        fixtures.messagingSupported.value = true
        let harness = makeSUT(chrome: .standalone, fixtures: fixtures)
        let receipt = try #require(MessagingSendReceipt(raw: ["message_id": .string("message"), "seq": .number(1),
            "status": .string("queued"), "delivery": .string("queue")]))
        let attempt = MessagingSubmissionAttempt(id: UUID(), runtime: runtime, runtimeEpoch: context.runtimeEpoch,
            taskID: "abc12345", operation: .send(now: false), outcome: .send(.receipt(receipt)))
        given(harness.useCase).submitTypedMessage(.any, text: .any, now: .any, acknowledgingUnconfirmed: .any, context: .any).willReturn(attempt)
        given(harness.useCase).isMessagingAttemptCurrent(.any).willReturn(true)
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.task != nil && harness.sut.messagingSupported == true }
        #expect(!harness.sut.messageBoxModel.showsSendNow)
        var accepted: Bool?
        // when
        harness.sut
.submitMessage("workflow draft", now: true) { accepted = $0 }
        await waitUntil { accepted != nil }
        #expect(accepted == false)
        var queuedAccepted: Bool?
        harness.sut
.submitMessage("workflow draft", now: false) { queuedAccepted = $0 }
        await waitUntil { queuedAccepted != nil }
        // then
        #expect(queuedAccepted == true)
        verify(harness.useCase).submitTypedMessage(.any, text: .any, now: .value(true), acknowledgingUnconfirmed: .any, context: .any).called(0)
        verify(harness.useCase).submitTypedMessage(.any, text: .any, now: .value(false), acknowledgingUnconfirmed: .any, context: .any).called(1)
    }

    @Test(arguments: [false, true], [TaskDetailChrome.standalone, .group, .embedded, .builder])
    func givenTaskSettlesBeforePresentationCatchesUp_whenSendNowIsCalled_thenNothingDispatches(stale: Bool, chrome: TaskDetailChrome) async {
        // given
        let fixtures = Fixtures()
        fixtures.detailBox.value = task(status: stale ? "running" : "failed")
        let runtime = QualificationRuntimeToken(client: CtlClient(executable: "/fixture/ctl", environment: [:]))
        fixtures.continuationRuntime.value = runtime
        fixtures.messagingContext.value = MessagingInvocationContext(runtime: runtime, runtimeEpoch: UUID())
        fixtures.messagingSupported.value = true
        let harness = makeSUT(isWorkflowBuilder: chrome == .builder, chrome: chrome, fixtures: fixtures)
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.task != nil && harness.sut.messagingSupported == true }
        if stale { #expect(harness.sut.task?.status == .running) }
        fixtures.detailBox.value = task(status: "failed")
        var accepted: Bool?
        // when — no publisher pulse: admission must consult the fresh status source.
        harness.sut
.submitMessage("exact draft", now: true) { accepted = $0 }
        // then
        #expect(accepted == false)
        #expect(!harness.sut.messageSendInFlight)
        verify(harness.useCase).submitTypedMessage(.any, text: .any, now: .any, acknowledgingUnconfirmed: .any, context: .any).called(0)
    }

    @Test(arguments: [TaskDetailChrome.standalone, .group, .embedded, .builder])
    func givenRunningSupportedTask_whenSendNowIsSubmitted_thenOneImmediateRequestIsAccepted(chrome: TaskDetailChrome) async throws {
        // given
        let fixtures = Fixtures()
        fixtures.detailBox.value = task(status: "running")
        let runtime = try #require(fixtures.messagingContext.value?.runtime)
        let context = MessagingInvocationContext(runtime: runtime, runtimeEpoch: UUID())
        fixtures.messagingContext.value = context
        fixtures.continuationRuntime.value = runtime
        fixtures.messagingSupported.value = true
        let harness = makeSUT(isWorkflowBuilder: chrome == .builder, chrome: chrome, fixtures: fixtures)
        let receipt = try #require(MessagingSendReceipt(raw: ["message_id": .string("message"), "seq": .number(1),
            "status": .string("queued"), "delivery": .string("now")]))
        let attempt = MessagingSubmissionAttempt(id: UUID(), runtime: runtime, runtimeEpoch: context.runtimeEpoch,
            taskID: "abc12345", operation: .send(now: true), outcome: .send(.receipt(receipt)))
        given(harness.useCase).submitTypedMessage(.any, text: .any, now: .any, acknowledgingUnconfirmed: .any, context: .any).willReturn(attempt)
        given(harness.useCase).isMessagingAttemptCurrent(.any).willReturn(true)
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.task != nil && harness.sut.messagingSupported == true }
        #expect(harness.sut.messageBoxModel.showsSendNow)
        var accepted: Bool?

        // when
        harness.sut
.submitMessage("immediate draft", now: true) { accepted = $0 }
        await waitUntil { accepted != nil }

        // then
        #expect(accepted == true)
        verify(harness.useCase).submitTypedMessage(.any, text: .any, now: .value(true), acknowledgingUnconfirmed: .any, context: .any).called(1)
    }

    @Test(arguments: [TaskDetailChrome.group, .embedded, .builder])
    func givenPresentedRunningTaskAndFreshTakeover_whenSendNowIsSubmitted_thenNoRequestDispatches(chrome: TaskDetailChrome) async {
        // given
        let fixtures = Fixtures()
        fixtures.detailBox.value = task(status: "running")
        let harness = makeSUT(isWorkflowBuilder: chrome == .builder, chrome: chrome, fixtures: fixtures)
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.task != nil && harness.sut.messagingSupported == true }
        #expect(harness.sut.task?.status == .running && harness.sut.task?.takenOver == false)
        fixtures.detailBox.value = task(status: "running", takenOver: true)
        var accepted: Bool?

        // when — the displayed task is still running, but its current detail has been taken over.
        harness.sut
.submitMessage("exact draft", now: true) { accepted = $0 }

        // then
        #expect(accepted == false)
        verify(harness.useCase).submitTypedMessage(.any, text: .any, now: .any, acknowledgingUnconfirmed: .any, context: .any).called(0)
    }

    @Test func givenNullWorkflowMetadata_whenTerminalStandaloneComposes_thenSendNowRemainsHiddenAndCannotDispatch() async throws {
        // given — canonical standalone listing metadata uses explicit null ownership fields.
        let fixtures = Fixtures()
        var raw = task(status: "failed").raw
        for key in ["workflow_run_id", "workflow_node_id", "workflow_role"] { raw[key] = .null }
        fixtures.detailBox.value = try #require(TaskInfo(.object(raw)))
        let harness = makeSUT(chrome: .standalone, fixtures: fixtures)
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.task != nil && harness.sut.messagingSupported == true }
        // when
        harness.sut.recomputeMessageBox(task: try #require(fixtures.detailBox.value))
        var accepted: Bool?
        harness.sut
.submitMessage("keep draft", now: true) { accepted = $0 }
        // then
        #expect(!harness.sut.messageBoxModel.showsSendNow)
        #expect(harness.sut.messageBoxModel.hint == "Send queues; Send now requests immediate delivery when safe")
        #expect(harness.sut.messageBoxModel.canSend)
        #expect(accepted == false)
        verify(harness.useCase).submitTypedMessage(.any, text: .any, now: .any, acknowledgingUnconfirmed: .any, context: .any).called(0)
    }

    @Test func givenMessageSupportIsUnknown_whenComposerRecomputes_thenSendNowIsHidden() async {
        // given
        let fixtures = Fixtures()
        fixtures.detailBox.value = task(status: "running")
        fixtures.messagingSupported.value = nil
        let harness = makeSUT(chrome: .standalone, fixtures: fixtures)
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        await waitUntil {
            harness.sut.task != nil && harness.sut.messagingSupportContext != nil && harness.sut.messagingSupported == nil
        }

        // when
        harness.sut.recomputeMessageBox(task: fixtures.detailBox.value!)

        // then
        #expect(harness.sut.messagingSupported == nil)
        #expect(!harness.sut.messageBoxModel.showsSendNow)
        #expect(harness.sut.messageBoxModel.hint.isEmpty)
    }

    @Test func givenMessageSupportIsUnsupported_whenComposerRecomputes_thenSendNowIsHidden() async {
        // given
        let fixtures = Fixtures()
        fixtures.detailBox.value = task(status: "running")
        fixtures.messagingSupported.value = false
        let harness = makeSUT(chrome: .standalone, fixtures: fixtures)
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.task != nil && harness.sut.messagingSupported == false }
        harness.sut.recomputeMessageBox(task: fixtures.detailBox.value!)

        // then
        #expect(!harness.sut.messageBoxModel.showsSendNow)
        #expect(harness.sut.messageBoxModel.hint.isEmpty)
    }

    @Test func givenPositiveMessageSupportBecomesStaleAndCurrentAgain_whenComposerRecomputes_thenVisibilityTracksIt() async {
        // given — resolve positive capability before making its context stale.
        let fixtures = Fixtures()
        fixtures.detailBox.value = task(status: "running")
        let harness = makeSUT(chrome: .standalone, fixtures: fixtures)
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.task != nil && harness.sut.messagingSupported == true }
        harness.sut.recomputeMessageBox(task: fixtures.detailBox.value!)
        #expect(harness.sut.messageBoxModel.showsSendNow)

        // when — the stored positive result is stale, then current again.
        fixtures.messagingCurrent.value = false
        harness.sut.recomputeMessageBox(task: fixtures.detailBox.value!)
        #expect(harness.sut.messagingSupported == true)
        #expect(!harness.sut.messageBoxModel.showsSendNow)
        #expect(harness.sut.messageBoxModel.hint.isEmpty)
        fixtures.messagingCurrent.value = true
        harness.sut.recomputeMessageBox(task: fixtures.detailBox.value!)

        // then
        #expect(harness.sut.messageBoxModel.showsSendNow)
        #expect(harness.sut.messageBoxModel.hint == "Send queues; Send now requests immediate delivery when safe")
    }

    @Test func givenQueueSubmissionAdmittedBeforeItsTaskRuns_whenContinueClicked_thenContinuationIsNotAdmitted() async {
        // given
        let fixture = HostedContinuationFixture()
        let context = MessagingInvocationContext(runtime: fixture.runtime, runtimeEpoch: UUID())
        fixture.fixtures.messagingContext.value = context
        fixture.fixtures.messagingSupported.value = true
        let cause = ConversationDeliveryNotDispatchedCause.launchFailed(tool: "harflow-ctl", detail: "fixture launch refused")
        let attempt = MessagingSubmissionAttempt(id: UUID(), runtime: fixture.runtime, runtimeEpoch: context.runtimeEpoch,
                                                taskID: fixture.sourceID, operation: .send(now: false), outcome: .send(.notDispatched(cause)))
        given(fixture.vm.useCase).submitTypedMessage(.any, text: .any, now: .any, acknowledgingUnconfirmed: .any, context: .any).willReturn(attempt)
        given(fixture.vm.useCase).isMessagingAttemptCurrent(.any).willReturn(true)
        fixture.vm.sut.didAppear()
        defer { fixture.vm.sut.didDisappear() }
        fixture.publish([HostedContinuationFixture.task()])
        await waitUntil { fixture.vm.sut.continuationPresentation?.canContinue == true && fixture.vm.sut.messagingSupported == true }
        var accepted: Bool?
        // when — synchronous queue admission occurs before the asynchronous submission can run.
        fixture.vm
.sut
.submitMessage("queued draft", now: false) { accepted = $0 }
        #expect(fixture.vm.sut.messageSendInFlight)
        #expect(fixture.vm.sut.continuationPresentation?.canContinue == false)
        fixture.vm.sut.didTapContinue(taskID: fixture.sourceID)
        // then
        #expect(fixture.vm.sut.continuationSession.submittedRequest == nil)
        let launches = await fixture.runner.continueCount
        #expect(launches == 0)
        await waitUntil { accepted != nil }
    }

    @Test func givenSourceLedgerConsumedByContinuation_whenFreshStatusArrives_thenDeliveredProjectionUsesSourceSuccessor() {
        // given
        let queued: [String: JSONValue] = ["task_id": .string("source"), "messages": .array([
            .object(["id": .string("m"), "seq": .number(1), "status": .string("queued"), "text": .string("queued text")])])]
        let delivered: [String: JSONValue] = ["task_id": .string("source"), "messages": .array([
            .object(["id": .string("m"), "seq": .number(1), "status": .string("delivered"), "successor_task_id": .string("successor")])])]
        // when / then
        #expect(WorkMessageBubble.project(raw: queued).first?.canCancel == true)
        let records = QueuedMessageState.project(raw: delivered, source: .standalone)
        #expect(records.first?.raw["successor_task_id"]?.stringValue == "successor")
        #expect(WorkMessageBubble.project(raw: delivered).isEmpty)
        #expect(WorkMessageOutcome.ledger(delivered) == "Message delivered.")
        #expect(WorkMessageBubble.project(raw: queued).count == 1)
    }
}
