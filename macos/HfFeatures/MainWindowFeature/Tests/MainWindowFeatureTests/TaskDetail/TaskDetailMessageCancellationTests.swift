import Foundation
@testable import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - TaskDetailMessageCancellationTests

extension TaskDetailVMTests {
    private func cancellationAttempt(status: String = "cancelled", unconfirmed: Bool = false) -> MessagingSubmissionAttempt {
        let receipt = MessagingCancelReceipt(raw: ["message_id": .string("message"), "status": .string(status)])!
        return MessagingSubmissionAttempt(id: UUID(), runtime: QualificationRuntimeToken(client: CtlClient(executable: "/fixture/ctl", environment: [:])),
                                          runtimeEpoch: UUID(), taskID: "abc12345", operation: .cancel(messageID: "message"),
                                          outcome: .cancel(unconfirmed ? .unconfirmed(.outputTooLarge(bytes: 1)) : .receipt(receipt)))
    }

    private func cancellationTask() -> TaskInfo {
        var raw = task().raw
        raw["messages"] = .array([.object([
            "id": .string("message"), "seq": .number(1), "status": .string("queued"), "text": .string("keep")])])
        return TaskInfo(.object(raw))!
    }

    @Test(arguments: ["queued", "delivering", "new-status", "cancelled"])
    func givenTypedCancelReceipt_whenCancelCompletes_thenOnlyCancelledRequestsFocus(status: String) async {
        // given
        let attempt = cancellationAttempt(status: status)
        let fixtures = Fixtures()
        fixtures.detailBox.value = cancellationTask()
        fixtures.messagingContext.value = MessagingInvocationContext(runtime: attempt.runtime, runtimeEpoch: attempt.runtimeEpoch)
        let harness = makeSUT(fixtures: fixtures)
        given(harness.useCase).cancelMessage(.any, messageID: .any, context: .any).willReturn(attempt)
        given(harness.useCase).isMessagingAttemptCurrent(.any).willReturn(true)
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.timelineModel.workMessages.first?.text == "keep" }
        // when
        harness.sut.cancelQueuedMessage("message")
        await waitUntil { harness.sut.messageCancellationAttempt != nil }
        // then
        #expect(harness.sut.messageOutcomeFocus == (status == "cancelled" ? attempt.id : nil))
        if status != "cancelled" {
            #expect(harness.sut.timelineModel.workMessages.first?.text == "keep")
        } else {
            #expect(harness.sut.timelineModel.workMessages.isEmpty)
        }
        verify(harness.useCase).cancelMessage(.any, messageID: .any, context: .any).called(1)
    }

    @Test func givenUnconfirmedCancellation_whenReceiptReturns_thenBubbleRemainsAndFocusIsNotRequested() async {
        // given
        let attempt = cancellationAttempt(unconfirmed: true)
        let fixtures = Fixtures()
        fixtures.detailBox.value = cancellationTask()
        fixtures.messagingContext.value = MessagingInvocationContext(runtime: attempt.runtime, runtimeEpoch: attempt.runtimeEpoch)
        let harness = makeSUT(fixtures: fixtures)
        given(harness.useCase).cancelMessage(.any, messageID: .any, context: .any).willReturn(attempt)
        given(harness.useCase).isMessagingAttemptCurrent(.any).willReturn(true)
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.timelineModel.workMessages.first?.text == "keep" }
        // when
        harness.sut.cancelQueuedMessage("message")
        await waitUntil { harness.sut.messageCancellationAttempt != nil }
        // then
        #expect(harness.sut.messageOutcomeFocus == nil)
        #expect(harness.sut.timelineModel.workMessages.first?.text == "keep")
        #expect(harness.sut.timelineModel.messageOutcome?.contains("could not be confirmed") == true)
        verify(harness.useCase).cancelMessage(.any, messageID: .any, context: .any).called(1)
    }

    @Test func givenConfirmedCurrentCancellation_whenFocusConsumedTwice_thenOnlyFirstRequestIsAccepted() {
        // given
        let harness = makeSUT()
        let attempt = cancellationAttempt()
        given(harness.useCase).isMessagingAttemptCurrent(.any).willReturn(true)
        harness.sut.isMounted = true
        harness.sut.messageCancellationAttempt = attempt
        harness.sut.messageOutcomeFocus = attempt.id
        // when / then
        #expect(harness.sut.consumeMessageOutcomeFocus(attempt.id))
        #expect(!harness.sut.consumeMessageOutcomeFocus(attempt.id))
    }

    @Test func givenStaleCancellation_whenFocusConsumed_thenNoFocusAndTokenIsDiscarded() {
        // given
        let harness = makeSUT()
        let attempt = cancellationAttempt()
        given(harness.useCase).isMessagingAttemptCurrent(.any).willReturn(false)
        harness.sut.isMounted = true
        harness.sut.messageCancellationAttempt = attempt
        harness.sut.messageOutcomeFocus = attempt.id
        // when / then
        #expect(!harness.sut.consumeMessageOutcomeFocus(attempt.id))
        #expect(harness.sut.messageOutcomeFocus == nil)
    }
}
