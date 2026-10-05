import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbCommon
import PbTestUtilities
import Testing

// MARK: - TaskDetailVMTests builder

extension TaskDetailVMTests {
    @Test func givenExactBuilderApprovalFailure_whenConfirmed_thenUpdatesOnlyRequestedHarnessAndDoesNotResume() async throws {
        // given
        let harness = makeSUT(isWorkflowBuilder: true)
        let builder = task(backend: "codex", status: "completed", liveInput: false)
        harness.detailBox.value = builder
        harness.sut.didAppear()
        harness.tasksSubject.send([builder])
        await waitUntil { harness.sut.task != nil }
        let event = try #require(TaskEvent(line: #"{"v":1,"seq":0,"kind":"notice","text":"MCP tool call requires approval, but approval policy is never"}"#))
        harness.sut.rawEvents = [event]
        given(harness.useCase).allowPolybridgeTools(backend: .value("codex")).willReturn([:])
        var captured: ViewEvent?
        let subscription = harness.sut.objectDidPublishViewEvent.publisher.sink { captured = $0 }
        // when
        #expect(harness.sut.polybridgeApprovalBackend == "codex")
        harness.sut.didTapAllowPolybridgeTools()
        await waitUntil { captured?.dialog != nil }
        let dialog = try #require(captured?.dialog)
        verify(harness.useCase).allowPolybridgeTools(backend: .any).called(0)
        dialog.actions.first?.action()
        // then
        await verify(harness.useCase).allowPolybridgeTools(backend: .value("codex")).calledEventually(1, before: .seconds(5))
        verify(harness.useCase).send(.any, text: .any).called(0)
        verify(harness.useCase).resume(.any, text: .any, onResumed: .any).called(0)
        withExtendedLifetime(subscription) {}
        harness.sut.didDisappear()
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["running", "completed"])
    func givenBuilderWithoutLiveInput_whenChatting_thenQueuesThroughBuilderSendAndDisablesOrdinaryControls(_ status: String) async {
        // given
        let harness = makeSUT(isWorkflowBuilder: true)
        let builder = task(status: status, liveInput: false)
        harness.detailBox.value = builder
        harness.sut.didAppear()
        harness.tasksSubject.send([builder])
        await waitUntil { harness.sut.task != nil }
        // when
        // Synchronize on the actual invocation, not a deadline racing the shared MainActor queue.
        let invocation = AsyncStream<Bool>.makeStream()
        when(harness.useCase).send(.value("abc12345"), text: .value("add review")).perform { invocation.continuation.yield(true) }
        let accepted = harness.sut.submitMessage("  add review  ")
        // then
        #expect(accepted)
        #expect(harness.sut.messageBoxModel.canSend || harness.sut.messageBoxModel.canContinue)
        #expect(!harness.sut.canTakeover)
        #expect(!harness.sut.canCancel)
        #expect(harness.sut.resumeCommand == nil)
        #expect(await invocation.stream.first(where: { @Sendable value in value }) == true)
        verify(harness.useCase).send(.value("abc12345"), text: .value("add review")).called(1)
        verify(harness.useCase).resume(.any, text: .any, onResumed: .any).called(0)
        harness.sut.didDisappear()
    }
}
