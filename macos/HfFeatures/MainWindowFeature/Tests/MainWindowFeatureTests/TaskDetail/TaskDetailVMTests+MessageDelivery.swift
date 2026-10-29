import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - TaskDetailVM message delivery

extension TaskDetailVMTests {
    @Test func givenSettledTask_whenSendingNow_thenRequestsImmediateDeliveryWithExactText() async {
        // given
        let harness = makeSUT()
        let settled = task(status: "completed")
        harness.detailBox.value = settled
        given(harness.useCase).sendNow(.any, text: .any).willReturn([:])
        harness.sut.didAppear()
        harness.tasksSubject.send([settled])
        await waitUntil { harness.sut.task != nil }
        // when
        #expect(harness.sut.submitMessageNow("  preserve my text  "))
        // then
        await verify(harness.useCase)
.sendNow(.value("abc12345"), text: .value("  preserve my text  "))
            .calledEventually(1, before: .seconds(5))
        verify(harness.useCase).send(.any, text: .any).called(0)
        harness.sut.didDisappear()
    }

    @Test func givenTakenOverTask_whenSendingNow_thenKeepsTheDraftAndDoesNotDispatch() async {
        // given
        let harness = makeSUT()
        let takenOver = task(status: "running", takenOver: true)
        harness.detailBox.value = takenOver
        harness.sut.didAppear()
        harness.tasksSubject.send([takenOver])
        await waitUntil { harness.sut.task != nil }
        // when / then
        #expect(!harness.sut.submitMessageNow("Keep this draft"))
        verify(harness.useCase).sendNow(.any, text: .any).called(0)
        harness.sut.didDisappear()
    }

    private func taskWithQueuedMessage(id messageID: String) throws -> TaskInfo {
        var raw = task(status: "running").raw
        raw["messages"] = .array([.object(["id": .string(messageID), "seq": .number(1), "status": .string("queued"), "text": .string("hold")])])
        return try #require(TaskInfo(.object(raw)))
    }

    private func sendNowResult(code: String, message: String, messageID: String) -> [String: JSONValue] {
        ["message_id": .string(messageID),
         "refusal": .object(["code": .string(code), "message": .string(message)])]
    }

    @Test func givenQueuedBubble_whenSendNowIsRefusedAsInterruptUnsupported_thenBubbleShowsSafeInterruptNote() async throws {
        // given
        let harness = makeSUT()
        let running = try taskWithQueuedMessage(id: "m1")
        harness.detailBox.value = running
        given(harness.useCase)
.sendNow(.any, text: .any)
            .willReturn(sendNowResult(code: "interrupt_unsupported", message: "engine text", messageID: "m1"))
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.timelineModel.workMessages.map(\.id) == ["m1"] }
        // when
        #expect(harness.sut.submitMessageNow("hold"))
        // then
        await waitUntil { harness.sut.timelineModel.workMessages.first?.note != nil }
        #expect(harness.sut.timelineModel.workMessages.first?.note == "Send now isn't available. This operation can't be interrupted safely.")
        #expect(harness.sut.timelineModel.workMessages.first?.canCancel == true)
        harness.sut.didDisappear()
    }

    @Test func givenQueuedBubble_whenSendNowIsRefusedWithAnotherCode_thenBubbleKeepsTheEngineMessage() async throws {
        // given
        let harness = makeSUT()
        let running = try taskWithQueuedMessage(id: "m1")
        harness.detailBox.value = running
        given(harness.useCase)
.sendNow(.any, text: .any)
            .willReturn(sendNowResult(code: "task_busy", message: "The task is busy.", messageID: "m1"))
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.timelineModel.workMessages.map(\.id) == ["m1"] }
        // when
        #expect(harness.sut.submitMessageNow("hold"))
        // then
        await waitUntil { harness.sut.timelineModel.workMessages.first?.note != nil }
        #expect(harness.sut.timelineModel.workMessages.first?.note == "The task is busy.")
        harness.sut.didDisappear()
    }

    @Test func givenRefusalForAnotherMessage_whenSendNowResolves_thenMatchingBubbleOnlyIsAnnotated() async throws {
        // given
        let harness = makeSUT()
        var raw = task(status: "running").raw
        raw["messages"] = .array([
            .object(["id": .string("m1"), "seq": .number(1), "status": .string("queued"), "text": .string("first")]),
            .object(["id": .string("m2"), "seq": .number(2), "status": .string("queued"), "text": .string("second")])])
        let running = try #require(TaskInfo(.object(raw)))
        harness.detailBox.value = running
        given(harness.useCase)
.sendNow(.any, text: .any)
            .willReturn(sendNowResult(code: "interrupt_unsupported", message: "x", messageID: "m2"))
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.timelineModel.workMessages.count == 2 }
        // when
        #expect(harness.sut.submitMessageNow("second"))
        // then
        await waitUntil { harness.sut.timelineModel.workMessages.last?.note != nil }
        #expect(harness.sut.timelineModel.workMessages.map(\.note) == [nil, "Send now isn't available. This operation can't be interrupted safely."])
        harness.sut.didDisappear()
    }

    @Test func givenSendNowResultWithoutRefusal_whenRemembered_thenNoNoteIsStored() async throws {
        // given
        let harness = makeSUT()
        let running = try taskWithQueuedMessage(id: "m1")
        harness.detailBox.value = running
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.timelineModel.workMessages.map(\.id) == ["m1"] }
        // when
        harness.sut.rememberMessageResult(["message_id": .string("m1")])
        harness.sut.rememberMessageResult(["refusal": .object(["code": .string("interrupt_unsupported")])])
        // then
        #expect(harness.sut.messageNotes.isEmpty)
        #expect(harness.sut.timelineModel.workMessages.first?.note == nil)
        harness.sut.didDisappear()
    }
}
