import Foundation
@testable import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - TaskDetailMessageSubmissionTests

extension TaskDetailVMTests {
    @Test(arguments: ["queued", "delivering", "delivered", "undeliverable", "cancelled", "future-status"])
    func givenTypedSendReceipt_whenSubmissionCompletes_thenOnlyRecognizedAcceptedStatusesClear(status: String) async {
        // given
        let runtime = QualificationRuntimeToken(client: CtlClient(executable: "/fixture/ctl", environment: [:]))
        let context = MessagingInvocationContext(runtime: runtime, runtimeEpoch: UUID())
        let fixtures = Fixtures()
        fixtures.detailBox.value = task()
        fixtures.continuationRuntime.value = runtime
        fixtures.messagingContext.value = context
        fixtures.messagingSupported.value = true
        let harness = makeSUT(fixtures: fixtures)
        let receipt = MessagingSendReceipt(raw: ["message_id": .string("message"), "seq": .number(1),
                                                 "status": .string(status), "delivery": .string("queue")])!
        let attempt = MessagingSubmissionAttempt(id: UUID(), runtime: runtime, runtimeEpoch: context.runtimeEpoch,
                                                taskID: "abc12345", operation: .send(now: false), outcome: .send(.receipt(receipt)))
        given(harness.useCase).submitTypedMessage(.any, text: .any, now: .any, acknowledgingUnconfirmed: .any, context: .any).willReturn(attempt)
        given(harness.useCase).isMessagingAttemptCurrent(.any).willReturn(true)
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.task != nil && harness.sut.messagingSupported == true }
        var cleared: Bool?
        // when
        harness.sut
.submitMessage("keep exact bytes", now: false) { cleared = $0 }
        await waitUntil { cleared != nil }
        // then
        #expect(cleared == ["queued", "delivering", "delivered", "undeliverable"].contains(status))
        verify(harness.useCase).submitTypedMessage(.any, text: .any, now: .any, acknowledgingUnconfirmed: .any, context: .value(context)).called(1)
    }

    @Test(arguments: [false, true])
    func givenUnconfirmedSend_whenQueueOrNowClickedAgain_thenNoAutomaticReplay(now: Bool) async {
        // given
        let runtime = QualificationRuntimeToken(client: CtlClient(executable: "/fixture/ctl", environment: [:]))
        let context = MessagingInvocationContext(runtime: runtime, runtimeEpoch: UUID())
        let fixtures = Fixtures()
        fixtures.detailBox.value = task()
        fixtures.continuationRuntime.value = runtime
        fixtures.messagingContext.value = context
        fixtures.messagingSupported.value = true
        let harness = makeSUT(fixtures: fixtures)
        let previous = MessagingSubmissionAttempt(id: UUID(), runtime: runtime, runtimeEpoch: context.runtimeEpoch,
                                                 taskID: "abc12345", operation: .send(now: !now),
                                                 outcome: .send(.unconfirmed(.outputTooLarge(bytes: 1))))
        fixtures.messagingAttempts.value = [previous]
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.task != nil && harness.sut.messagingSupported == true }
        // when
        harness.sut.submitMessage("same draft", now: now) { _ in }
        // then
        verify(harness.useCase).submitTypedMessage(.any, text: .any, now: .any, acknowledgingUnconfirmed: .any, context: .any).called(0)
        #expect(!harness.sut.messageSendInFlight)
    }

    @Test(arguments: [false, true])
    func givenCapabilityRead_whenSupportIsKnown_thenComposerUsesCurrentCapability(supported: Bool) async {
        // given
        let runtime = QualificationRuntimeToken(client: CtlClient(executable: "/fixture/ctl", environment: [:]))
        let context = MessagingInvocationContext(runtime: runtime, runtimeEpoch: UUID())
        let fixtures = Fixtures()
        fixtures.detailBox.value = task()
        fixtures.continuationRuntime.value = runtime
        fixtures.messagingContext.value = context
        fixtures.messagingSupported.value = true
        let harness = makeSUT(fixtures: fixtures)
        fixtures.messagingSupported.value = supported
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.task != nil && harness.sut.messagingSupported != nil }
        // when
        let model = harness.sut.messageBoxModel
        // then
        #expect(model.canSend == supported)
        #expect(model.showsSendNow == supported)
        if !supported {
            #expect(model.isLocked)
            #expect(model.placeholder.isEmpty)
            #expect(model.hint.isEmpty)
        }
    }
}
