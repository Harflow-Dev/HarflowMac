import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbRepository
import Testing

// MARK: - TaskDetailViewRepositoryTests builder

extension TaskDetailViewRepositoryTests {
    @Test(arguments: [false, true])
    func givenBuilderConversation_whenSendingOrContinuing_thenUsesScopedFollowupAndReportsQueuedOutcome(_ continuing: Bool) async throws {
        // given
        let workflow = MockWorkflowRepository()
        let actions = MockTaskActionRepository()
        let listing = MockTaskListRepository()
        given(workflow)
.command(.value("builder-followup"), options: .value(["--prompt=add review"]), positionals: .value(["builder-run"]))
            .willReturn(["status": .string("queued_next_turn")])
        given(actions).setOutcome(.any, .any).willReturn()
        given(listing).refresh().willReturn()
        let sut = TaskDetailViewRepository(taskListRepository: listing, taskActionRepository: actions,
                                           builderRunID: "builder-run", workflowRepository: workflow)
        // when
        if continuing {
            let newTask = try await sut.resume("task", text: "add review") { _ in Issue.record("A queued message must not fabricate a resumed task") }
            #expect(newTask == nil)
        } else {
            #expect(try await sut.send("task", text: "add review"))
        }
        // then
        verify(workflow)
.command(.value("builder-followup"), options: .value(["--prompt=add review"]), positionals: .value(["builder-run"]))
            .called(1)
        verify(actions).setOutcome(.value("task"), .value("Queued for the next builder turn.")).called(1)
        verify(actions).send(.any, text: .any).called(0)
        verify(actions).resume(.any, text: .any, onResumed: .any).called(0)
    }
}
