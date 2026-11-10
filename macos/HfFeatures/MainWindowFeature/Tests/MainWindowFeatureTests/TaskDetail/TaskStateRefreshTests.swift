import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import Testing

// MARK: - TaskStateRefreshTests

@MainActor
struct TaskStateRefreshTests {
    @Test func givenConversationAdvanced_whenRefreshing_thenCurrentMemberIsReadOnce() async {
        // given
        let fixtures = TaskDetailVMTests()
        let first = fixtures.conversationTask("first")
        let current = fixtures.conversationTask("current", status: "running", parentTaskID: "first", minute: 1)
        let harness = fixtures.makeConversationSUT(openedAs: "first", initialMembers: [first], stubbedMembers: [first, current])
        given(harness.useCase).refreshSnapshot(.any).willReturn()
        harness.sut.didAppear()
        harness.tasksSubject.send([first])
        await waitUntil { harness.sut.task?.taskID == "first" }
        harness.membersBox.value = [first, current]
        harness.tasksSubject.send([first, current])
        await waitUntil { harness.sut.task?.taskID == "current" }
        // when
        harness.sut.didTapRefreshState()
        // then
        await verify(harness.useCase).refreshSnapshot(.value("current")).calledEventually(1, before: .seconds(5))
        verify(harness.useCase).refreshSnapshot(.value("first")).called(0)
        harness.sut.didDisappear()
    }
}
