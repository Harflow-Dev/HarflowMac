import Foundation
import HfCommon
@testable import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
@testable import MonitorCore
import Testing

// MARK: - MessagingLifecycleFixture

@MainActor
private struct MessagingLifecycleFixture {
    let fixtures = TaskDetailVMTests.Fixtures()
    let runtime = QualificationRuntimeToken(client: CtlClient(executable: "/fixture/ctl", environment: [:]))
    let context: MessagingInvocationContext
    let base: TaskDetailVMTests.SUT
    let wrapper: SuspendedMessagingUseCase
    let sut: TaskDetailVM
    let currentAttempt = TaskDetailVMTests.Box(true)

    init() {
        self.context = MessagingInvocationContext(runtime: runtime, runtimeEpoch: UUID())
        fixtures.detailBox.value = TaskDetailVMTests().task()
        fixtures.continuationRuntime.value = runtime
        fixtures.messagingContext.value = context
        fixtures.messagingSupported.value = true
        self.base = TaskDetailVMTests().makeSUT(fixtures: fixtures)
        self.wrapper = SuspendedMessagingUseCase(base: base.useCase)
        self.sut = TaskDetailVM(taskID: "abc12345", useCase: wrapper, routing: base.routing,
                           continuityHistory: TaskContinuityHistoryStore(), chrome: .group, scheduler: NullScheduling())
        let current = currentAttempt
        given(base.useCase).isMessagingAttemptCurrent(.any).willProduce { _ in current.value }
    }

    func attempt(_ outcome: MessagingOutcome<MessagingSendReceipt>, now: Bool = false) -> MessagingSubmissionAttempt {
        MessagingSubmissionAttempt(id: UUID(), runtime: runtime, runtimeEpoch: context.runtimeEpoch,
                                   taskID: "abc12345", operation: .send(now: now), outcome: .send(outcome))
    }

    func acknowledged() -> MessagingSubmissionAttempt {
        attempt(.receipt(MessagingSendReceipt(raw: ["message_id": .string("message"), "seq": .number(1),
                                                    "status": .string("queued"), "delivery": .string("queue")])!))
    }

    func appear() async {
        sut.didAppear()
        await waitUntil { sut.task != nil && sut.messagingSupported == true }
    }
}

// MARK: - TaskDetailMessagingLifecycleTests

extension TaskDetailVMTests {
    @Test(arguments: ["mounted", "unmounted", "stale"])
    func givenSuspendedSend_whenOtherModeClickedAndLifecycleChanges_thenOnlyCurrentAcceptanceClearsOriginalDraft(scenario: String) async {
        // given
        let fixture = MessagingLifecycleFixture()
        given(fixture.base.useCase)
.submitTypedMessage(.any, text: .any, now: .any,
                                                      acknowledgingUnconfirmed: .any, context: .any)
.willReturn(fixture.acknowledged())
        await fixture.appear()
        defer { fixture.sut.didDisappear() }
        let store = TaskDraftStore()
        let mount = store.makeMount(key: "abc12345", members: ["abc12345"], partition: .empty) { "abc12345" }
        mount.text.wrappedValue = "captured draft"
        let clear = mount.captureAcceptedDraftClear()
        var accepted: Bool?
        fixture.sut
.submitMessage("captured draft", now: false) { result in
            accepted = result
            if result { clear() }
        }
        await waitUntil { fixture.wrapper.gate.arrived }
        // when — the first call is suspended across a real await, not merely queued for scheduling.
        var second: Bool?
        fixture.sut
.submitMessage("second", now: true) { second = $0 }
        #expect(second == false)
        #expect(fixture.sut.messageSendInFlight)
        if scenario == "unmounted" { fixture.sut.didDisappear() }
        if scenario == "stale" { fixture.currentAttempt.value = false }
        fixture.wrapper.gate.release()
        await waitUntil { accepted != nil }
        // then
        #expect(accepted == (scenario != "stale"))
        #expect(mount.text.wrappedValue == (scenario == "stale" ? "captured draft" : ""))
        verify(fixture.base.useCase)
.submitTypedMessage(.any, text: .any, now: .value(false),
                                                       acknowledgingUnconfirmed: .any, context: .any)
.called(1)
        verify(fixture.base.useCase)
.submitTypedMessage(.any, text: .any, now: .value(true),
                                                       acknowledgingUnconfirmed: .any, context: .any)
.called(0)
    }

    @Test func givenInitialUnconfirmedSend_whenOwnerCompletesThenComposerRecomputes_thenDraftAndVisibleWarningRemain() async {
        // given
        let fixture = MessagingLifecycleFixture()
        let attempt = fixture.attempt(.unconfirmed(.outputTooLarge(bytes: 1)))
        given(fixture.base.useCase)
.submitTypedMessage(.any, text: .any, now: .any,
                                                      acknowledgingUnconfirmed: .any, context: .any)
.willReturn(attempt)
        await fixture.appear()
        defer { fixture.sut.didDisappear() }
        var draft = "keep"
        var completed = false
        // when
        fixture.sut.submitMessage(draft, now: false) { accepted in
            if accepted { draft = "" }
            completed = true
        }
        await waitUntil { fixture.wrapper.gate.arrived }
        fixture.wrapper.gate.release()
        await waitUntil { completed && !fixture.sut.messageSendInFlight }
        fixture.sut.recomputeMessageBox(task: fixture.sut.task!)
        // then
        #expect(draft == "keep")
        #expect(fixture.sut.messageSendOutcome == "Sending could not be confirmed. The message may already have been queued.")
        #expect(fixture.sut.timelineModel.messageOutcome == fixture.sut.messageSendOutcome)
    }

    @Test(arguments: [false, true])
    func givenEarlierRuntimeEpoch_whenRemounted_thenOnlyUnsafeUncertaintyRemains(unsafe: Bool) async {
        // given
        let fixture = MessagingLifecycleFixture()
        fixture.fixtures.messagingAttempts.value = [unsafe
            ? fixture.attempt(.unconfirmed(.outputTooLarge(bytes: 1))) : fixture.acknowledged()]
        fixture.currentAttempt.value = false
        // when — the same runtime token has returned with a different owner epoch.
        fixture.fixtures.messagingContext.value = MessagingInvocationContext(runtime: fixture.runtime, runtimeEpoch: UUID())
        await fixture.appear()
        defer { fixture.sut.didDisappear() }
        // then
        #expect(fixture.sut.messageSendOutcome == (unsafe
            ? "Sending could not be confirmed. The message may already have been queued." : nil))
    }

    @Test func givenCapacityAdmissionFailure_whenComposerRecomputes_thenFreshErrorSurvivesOlderAttemptRehydration() async {
        // given
        let fixture = MessagingLifecycleFixture()
        fixture.fixtures.messagingAttempts.value = [fixture.acknowledged()]
        given(fixture.base.useCase)
.submitTypedMessage(.any, text: .any, now: .any,
                                                      acknowledgingUnconfirmed: .any, context: .any)
.willThrow(MessagingAdmissionError.capacity)
        await fixture.appear()
        defer { fixture.sut.didDisappear() }
        var complete = false
        fixture.sut.submitMessage("keep", now: false) { _ in complete = true }
        await waitUntil { fixture.wrapper.gate.arrived }
        // when
        fixture.wrapper.gate.release()
        await waitUntil { complete && !fixture.sut.messageSendInFlight }
        let error = fixture.sut.messageSendOutcome
        fixture.sut.recomputeMessageBox(task: fixture.sut.task!)
        // then
        #expect(error != nil)
        #expect(error != "Queued — not yet delivered.")
        #expect(fixture.sut.messageSendOutcome == error)
    }

    @Test(arguments: [false, true])
    func givenSupersededRefusal_whenOpenNamedSuccessorConfirmed_thenOnlyStructuredListedIdentityRoutes(structured: Bool) async throws {
        // given
        let fixture = MessagingLifecycleFixture()
        let successor = String(repeating: "b", count: 32)
        var successorRaw = TaskDetailVMTests().task().raw
        successorRaw["task_id"] = .string(successor)
        let successorTask = try #require(TaskInfo(.object(successorRaw)))
        fixture.fixtures.taskProvider.value = { id in id == successor ? successorTask : TaskDetailVMTests().task(id: id) }
        let error = MessagingSendError(ConversationDeliveryEngineError(code: "superseded", message: "Open " + successor,
                                                                       data: structured ? ["successor_task_id": .string(successor)] : nil))
        given(fixture.base.useCase)
.submitTypedMessage(.any, text: .any, now: .any,
                                                      acknowledgingUnconfirmed: .any, context: .any)
.willReturn(fixture.attempt(.refused(error)))
        await fixture.appear()
        defer { fixture.sut.didDisappear() }
        var event: ViewEvent?
        let subscription = fixture.sut.objectDidPublishViewEvent.publisher.sink { event = $0 }
        defer { subscription.cancel() }
        var accepted: Bool?
        // when
        fixture.sut
.submitMessage("keep draft", now: false) { accepted = $0 }
        await waitUntil { fixture.wrapper.gate.arrived }
        fixture.wrapper.gate.release()
        await waitUntil { accepted != nil && !fixture.sut.messageSendInFlight }
        if case .dialog(let dialog) = event { dialog.actions.first?.action() }
        // then
        #expect(accepted == false)
        #expect(fixture.sut.messageSendOutcome == error.message)
        verify(fixture.base.routing).selectTask(.value(successor)).called(structured ? 1 : 0)
    }

    @Test func givenRetainedUnconfirmedAttempt_whenWarningExplicitlyAccepted_thenSendAcknowledgesExactUUID() async {
        // given
        let fixture = MessagingLifecycleFixture()
        let previous = fixture.attempt(.unconfirmed(.outputTooLarge(bytes: 1)))
        fixture.fixtures.messagingAttempts.value = [previous]
        given(fixture.base.useCase)
.submitTypedMessage(.any, text: .any, now: .any,
                                                      acknowledgingUnconfirmed: .value(previous.id), context: .any)
.willReturn(fixture.acknowledged())
        await fixture.appear()
        defer { fixture.sut.didDisappear() }
        var event: ViewEvent?
        let subscription = fixture.sut.objectDidPublishViewEvent.publisher.sink { event = $0 }
        defer { subscription.cancel() }
        // when
        fixture.sut.submitMessage("resend", now: false) { _ in }
        guard case .dialog(let dialog) = event else { Issue.record("Expected resend warning"); return }
        #expect(dialog.description?.contains("may already have been accepted") == true)
        dialog.actions.first?.action()
        await waitUntil { fixture.wrapper.gate.arrived }
        fixture.wrapper.gate.release()
        await waitUntil { !fixture.sut.messageSendInFlight }
        // then
        verify(fixture.base.useCase)
.submitTypedMessage(.any, text: .value("resend"), now: .value(false),
                                                       acknowledgingUnconfirmed: .value(previous.id), context: .value(fixture.context))
.called(1)
    }
}
