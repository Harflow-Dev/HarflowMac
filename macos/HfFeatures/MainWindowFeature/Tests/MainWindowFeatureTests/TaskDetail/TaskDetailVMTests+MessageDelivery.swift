import Foundation
@testable import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - TaskDetailVM message delivery

extension TaskDetailVMTests {
    @Test(arguments: ["interrupt_unsupported", "workflow_checkpoint_required", "continuation_refused", "future-code"])
    func givenQueuedReceiptWithRefusal_whenSentNow_thenAcceptanceKeepsQueuedCancelAndCorrectNote(code: String) async throws {
        // given
        let runtime = QualificationRuntimeToken(client: CtlClient(executable: "/fixture/ctl", environment: [:]))
        let context = MessagingInvocationContext(runtime: runtime, runtimeEpoch: UUID())
        let fixtures = Fixtures()
        fixtures.continuationRuntime.value = runtime
        fixtures.messagingContext.value = context
        fixtures.messagingSupported.value = true
        let harness = makeSUT(fixtures: fixtures)
        var raw = task(status: "running").raw
        raw["messages"] = .array([.object(["id": .string("m1"), "seq": .number(1), "status": .string("queued"), "text": .string("hold")])])
        let running = try #require(TaskInfo(.object(raw)))
        harness.detailBox.value = running
        let receipt = MessagingSendReceipt(raw: ["message_id": .string("m1"), "seq": .number(1),
                                                 "status": .string("queued"), "delivery": .string("now"),
                                                 "refusal": .object(["code": .string(code), "message": .string("Engine explanation")])])!
        let attempt = MessagingSubmissionAttempt(id: UUID(), runtime: runtime, runtimeEpoch: context.runtimeEpoch,
                                                taskID: "abc12345", operation: .send(now: true), outcome: .send(.receipt(receipt)))
        given(harness.useCase).submitTypedMessage(.any, text: .any, now: .any, acknowledgingUnconfirmed: .any, context: .any).willReturn(attempt)
        given(harness.useCase).isMessagingAttemptCurrent(.any).willReturn(true)
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.messagingSupported == true && harness.sut.timelineModel.workMessages.count == 1 }
        var accepted: Bool?
        // when
        harness.sut
.submitMessage("  preserve exact text  ", now: true) { accepted = $0 }
        await waitUntil { accepted != nil }
        // then
        #expect(accepted == true)
        #expect(harness.sut.timelineModel.workMessages.first?.canCancel == true)
        #expect(harness.sut.timelineModel.workMessages.first?.note == (code == "interrupt_unsupported"
            ? "Send now isn't available. This operation can't be interrupted safely." : "Engine explanation"))
        verify(harness.useCase)
.submitTypedMessage(.value("abc12345"), text: .value("  preserve exact text  "), now: .value(true),
                                                 acknowledgingUnconfirmed: .value(nil), context: .value(context))
.called(1)
        verify(harness.useCase).sendNow(.any, text: .any).called(0)
    }

    @Test func givenTakenOverTask_whenSendingNow_thenKeepsTheDraftAndDoesNotDispatch() async {
        // given
        let harness = makeSUT()
        harness.detailBox.value = task(status: "running", takenOver: true)
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.task != nil }
        // when / then
        #expect(!harness.sut.submitMessageNow("Keep this draft"))
        verify(harness.useCase).submitTypedMessage(.any, text: .any, now: .any, acknowledgingUnconfirmed: .any, context: .any).called(0)
    }
}
