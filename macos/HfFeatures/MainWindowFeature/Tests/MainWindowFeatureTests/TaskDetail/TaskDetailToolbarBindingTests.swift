import Combine
import HfCommon
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - TaskDetailToolbarBindingTests

/// More → Stop is bound to the view model's `didTapCancel` through the production factory, never a test-supplied closure.
@MainActor
@Suite struct TaskDetailToolbarBindingTests {
    private func toolbarActions(_ sut: TaskDetailVM, task: TaskInfo) -> TaskDetailToolbarActions {
        TaskDetailView<TaskDetailVM>.toolbarActions(
            viewModel: sut, task: task,
            hooks: TaskDetailToolbarHooks(showRawEvents: {}, toggleInspector: {}, openRepository: { _ in },
                                          revealContinuity: {}, revealNotices: {}, revealAccess: {})
        )
    }

    @Test func givenStandaloneTask_whenToolbarCancelActionRuns_thenStopConfirmationIsPresented() async {
        // given
        let fixtures = TaskDetailVMTests()
        let task = fixtures.task()
        let direct = fixtures.makeSUT(chrome: .standalone)
        let bound = fixtures.makeSUT(chrome: .standalone)
        var directRequests: [TaskStopConfirmation] = []
        var boundRequests: [TaskStopConfirmation] = []
        given(direct.routing).presentStopConfirmation(.any).willProduce { directRequests.append($0) }
        given(bound.routing).presentStopConfirmation(.any).willProduce { boundRequests.append($0) }
        for harness in [direct, bound] {
            harness.detailBox.value = task
            harness.sut.didAppear()
            harness.tasksSubject.send([task])
        }
        defer { direct.sut.didDisappear(); bound.sut.didDisappear() }
        await waitUntil { direct.sut.canCancel && bound.sut.canCancel }

        // precondition: the direct call presents exactly once on an identical fixture
        direct.sut.didTapCancel()
        await waitUntil { directRequests.count == 1 }
        #expect(directRequests.count == 1)

        // when
        toolbarActions(bound.sut, task: task).cancel()
        await waitUntil { boundRequests.count == 1 }

        // then
        #expect(boundRequests.count == 1)
        #expect(boundRequests.first?.taskID == task.taskID)
        verify(bound.useCase).cancel(.any).called(0)
    }

    @Test func givenGroupTask_whenToolbarCancelActionRuns_thenTheLegacyDialogShowsAndNothingIsCancelledYet() async {
        // given
        let fixtures = TaskDetailVMTests()
        let task = fixtures.task()
        let harness = fixtures.makeSUT(chrome: .group)
        var presented = 0
        given(harness.routing).presentStopConfirmation(.any).willProduce { _ in presented += 1 }
        harness.detailBox.value = task
        var event: ViewEvent?
        let cancellable = harness.sut.objectDidPublishViewEvent.publisher.sink { event = $0 }
        defer { cancellable.cancel(); harness.sut.didDisappear() }
        harness.sut.didAppear()
        harness.tasksSubject.send([task])
        await waitUntil { harness.sut.canCancel }

        // when
        toolbarActions(harness.sut, task: task).cancel()
        await waitUntil { event?.dialog != nil }

        // then
        #expect(event?.dialog?.title == "Cancel this task?")
        #expect(presented == 0)
        verify(harness.useCase).cancel(.any).called(0)
    }
}
