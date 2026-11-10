import Combine
import Foundation
import HfCommon
import HfCommonTestMock
import HfRepository
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

@MainActor
@Suite struct MainWindowStopConfirmationTests {
    @Test func givenStopRequest_whenConfirmedTwice_thenCallbackRunsOnceAfterDismissal() {
        // given
        let sut = MainWindowCoordinator(parent: MockCoordinator())
        sut.selection = .task("task")
        var confirmations = 0
        let request = TaskStopConfirmation(conversationID: "task", taskID: "task", notStoppedTitles: []) {
            #expect(sut.stopConfirmation == nil)
            #expect(sut.presentedSheet == nil)
            confirmations += 1
        }
        sut.presentStopConfirmation(request)
        // when
        sut.confirmStop(requestID: UUID())
        #expect(confirmations == 0)
        sut.confirmStop(requestID: request.id)
        sut.confirmStop(requestID: request.id)
        // then
        #expect(confirmations == 1)
    }

    @Test func givenStopRequest_whenSheetReplaced_thenCapturedCallbackCannotRun() {
        // given
        let sut = MainWindowCoordinator(parent: MockCoordinator())
        sut.selection = .task("task")
        var confirmations = 0
        let request = TaskStopConfirmation(conversationID: "task", taskID: "task", notStoppedTitles: []) { confirmations += 1 }
        sut.presentStopConfirmation(request)
        // when
        sut.presentedSheet = .workflowRunner
        sut.confirmStop(requestID: request.id)
        // then
        #expect(sut.stopConfirmation == nil)
        #expect(sut.presentedSheet == .workflowRunner)
        #expect(confirmations == 0)
    }

    @Test func givenStopRequest_whenNavigatingAway_thenRequestIsDiscarded() {
        // given
        let sut = MainWindowCoordinator(parent: MockCoordinator())
        sut.selection = .task("task")
        let request = TaskStopConfirmation(conversationID: "task", taskID: "task", notStoppedTitles: []) {}
        sut.presentStopConfirmation(request)
        #expect(sut.presentedSheet == .stopTask)
        // when
        sut.selection = .task("other")
        // then
        #expect(sut.stopConfirmation == nil)
        #expect(sut.presentedSheet == nil)
    }

    @Test func givenCompetingSheet_whenStopRequested_thenExistingSheetIsPreserved() {
        // given
        let sut = MainWindowCoordinator(parent: MockCoordinator())
        sut.selection = .task("task")
        sut.presentedSheet = .workflowRunner
        // when
        sut.presentStopConfirmation(TaskStopConfirmation(conversationID: "task", taskID: "task", notStoppedTitles: []) {})
        // then
        #expect(sut.presentedSheet == .workflowRunner)
        #expect(sut.stopConfirmation == nil)
    }

    @Test func givenStopRequest_whenNavigatingToSameConversationMember_thenRequestIsRetained() {
        // given
        let fixtures = TaskDetailVMTests()
        let tasks = [fixtures.conversationTask("a"), fixtures.conversationTask("b", status: "running", parentTaskID: "a", minute: 1)]
        let listing = MockTaskListRepository()
        given(listing).tasks.willReturn(tasks)
        given(listing).tasksPublisher().willReturn(Empty<[TaskInfo], Never>().eraseToAnyPublisher())
        given(listing).hasListed.willReturn(true)
        given(listing).listError.willReturn(nil)
        given(listing).hasListedPublisher().willReturn(Just(true).eraseToAnyPublisher())
        given(listing).listErrorPublisher().willReturn(Just<ToolError?>(nil).eraseToAnyPublisher())
        let sut = MainWindowCoordinator(parent: MockCoordinator(), taskListRepository: listing)
        sut.selection = .task("a")
        let request = TaskStopConfirmation(conversationID: "a", taskID: "b", notStoppedTitles: []) {}
        sut.presentStopConfirmation(request)
        // when
        sut.selection = .task("b")
        // then
        #expect(sut.presentedSheet == .stopTask)
        #expect(sut.stopConfirmation?.id == request.id)
    }

}
