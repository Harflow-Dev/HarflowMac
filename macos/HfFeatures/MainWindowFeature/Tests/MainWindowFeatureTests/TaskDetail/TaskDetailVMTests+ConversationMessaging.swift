import Foundation
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import Testing

// MARK: - Conversation messaging

extension TaskDetailVMTests {

    // MARK: - Continue does not navigate (Design point 7)

    @Test(.timeLimit(.minutes(1))) func givenAnEligibleContinue_whenSubmitted_thenItTargetsTheCurrentMemberAndNeverSelectsTheNewTask() async {
        // given
        let taskA = conversationTask("a", status: "completed", minute: 0)
        let harness = makeConversationSUT(openedAs: "a", initialMembers: [taskA])
        harness.useCase.configureTypedSendSuccess()
        harness.sut.didAppear()
        harness.tasksSubject.send([taskA])
        await waitUntil { harness.sut.task != nil && harness.sut.messagingSupported == true }

        // when
        // Synchronize on the actual invocation, not a deadline racing the shared MainActor queue.
        let invocation = AsyncStream<Bool>.makeStream()
        when(harness.useCase)
.submitTypedMessage(.value("a"), text: .value("one more thing"), now: .value(false),
            acknowledgingUnconfirmed: .any, context: .any)
.perform { invocation.continuation.yield(true) }
        harness.sut.submitMessage("one more thing", now: false) { _ in }

        // then
        #expect(await invocation.stream.first(where: { @Sendable value in value }) == true)
        verify(harness.useCase)
.submitTypedMessage(.value("a"), text: .value("one more thing"), now: .value(false),
            acknowledgingUnconfirmed: .any, context: .any)
.called(1)
        try? await Task.sleep(for: .milliseconds(50))
        verify(harness.routing).selectTask(.any).called(0)
    }

}
