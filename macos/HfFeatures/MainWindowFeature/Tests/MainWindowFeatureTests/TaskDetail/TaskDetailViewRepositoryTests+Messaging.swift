import Foundation
@testable import HfRepository
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - TaskDetailViewRepository messaging tests

extension TaskDetailViewRepositoryTests {
    @Test func givenTypedCancelAttempt_whenCancelling_thenOwnerEvidenceIsReturnedWithoutInventingAnOutcome() async throws {
        // given
        let actions = MockTaskActionRepository()
        let receipt = MessagingCancelReceipt(raw: ["message_id": .string("message"), "status": .string("queued"),
                                                   "refusal": .object(["code": .string("changed"), "message": .string("Already claimed")])])!
        let runtime = QualificationRuntimeToken(client: CtlClient(executable: "/fixture/ctl", environment: [:]))
        let attempt = MessagingSubmissionAttempt(id: UUID(), runtime: runtime,
                                                runtimeEpoch: UUID(), taskID: "task", operation: .cancel(messageID: "message"),
                                                outcome: .cancel(.receipt(receipt)))
        let context = MessagingCancellationContext(runtime: runtime, runtimeEpoch: attempt.runtimeEpoch)
        given(actions).cancelQueuedMessage(.value("task"), messageID: .value("message"), context: .value(context)).willReturn(attempt)
        given(actions).isMessagingAttemptCurrent(.value(attempt)).willReturn(false)
        let sut = TaskDetailViewRepository(taskActionRepository: actions)
        // when
        let result = try await sut.cancelMessage("task", messageID: "message", context: context)
        // then
        #expect(result == attempt)
        #expect(!sut.isMessagingAttemptCurrent(result))
        verify(actions).setOutcome(.any, .any).called(0)
        verify(actions).cancelQueuedMessage(.value("task"), messageID: .value("message"), context: .value(context)).called(1)
    }
}
