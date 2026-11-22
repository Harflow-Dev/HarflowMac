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

    @Test func givenCancelledStop_whenDismissalsArrive_thenOnlyTheMatchingCurrentRequestRestoresFocus() {
        // given
        let sut = MainWindowCoordinator(parent: MockCoordinator())
        sut.selection = .task("task")
        var restores: [String] = []
        let first = TaskStopConfirmation(conversationID: "task", taskID: "first", notStoppedTitles: [], confirm: {}) {
            restores.append("first")
        }
        sut.presentStopConfirmation(first)
        sut.cancelStop(requestID: first.id)
        let second = TaskStopConfirmation(conversationID: "task", taskID: "second", notStoppedTitles: [], confirm: {}) {
            restores.append("second")
        }
        sut.presentStopConfirmation(second)
        sut.cancelStop(requestID: second.id)

        // when — an older sheet's late dismissal arrives before the current sheet's native dismissal.
        sut.taskStopSheetDidDismiss(requestID: first.id)
        sut.taskStopSheetDidDismiss(requestID: second.id)
        sut.taskStopSheetDidDismiss(requestID: second.id)

        // then
        #expect(restores == ["second"])
        #expect(sut.stopConfirmation == nil)
        #expect(sut.cancelledTaskStop == nil)
    }

    @Test func givenStopReplacedBeforeNativeAttachment_whenLaterStopIsCancelled_thenOnlyLaterRequestRestores() {
        let sut = MainWindowCoordinator(parent: MockCoordinator())
        sut.selection = .task("task")
        var restored: [String] = []
        let replaced = TaskStopConfirmation(conversationID: "task", taskID: "replaced", notStoppedTitles: [], confirm: {}) {
            restored.append("replaced")
        }
        sut.presentStopConfirmation(replaced)

        sut.presentedSheet = .workflowRunner
        sut.presentedSheet = nil
        let later = TaskStopConfirmation(conversationID: "task", taskID: "later", notStoppedTitles: [], confirm: {}) {
            restored.append("later")
        }
        sut.presentStopConfirmation(later)
        sut.taskStopSheetDidDismiss(requestID: replaced.id)
        sut.cancelStop(requestID: later.id)
        sut.taskStopSheetDidDismiss(requestID: later.id)

        #expect(restored == ["later"])
        #expect(sut.stopConfirmation == nil)
        #expect(sut.cancelledTaskStop == nil)
    }

    @Test func givenNativeSheetDismissal_whenStandaloneStopIsCurrent_thenDismissalIsClassifiedAsCancellation() {
        // given
        let sut = MainWindowCoordinator(parent: MockCoordinator())
        sut.selection = .task("task")
        var dismissals = 0
        let request = TaskStopConfirmation(conversationID: "task", taskID: "task", notStoppedTitles: [], confirm: {}) {
            dismissals += 1
        }
        sut.presentStopConfirmation(request)

        // when — the sheet binding reports Escape or another user initiated dismissal.
        sut.dismissPresentedSheet()
        sut.taskStopSheetDidDismiss(requestID: request.id)

        // then
        #expect(sut.presentedSheet == nil)
        #expect(dismissals == 1)
    }

    @Test func givenCancelledStop_whenConversationChangesBeforeDismissal_thenFocusIsNotRestored() {
        // given
        let sut = MainWindowCoordinator(parent: MockCoordinator())
        sut.selection = .task("task")
        var dismissals = 0
        let request = TaskStopConfirmation(conversationID: "task", taskID: "task", notStoppedTitles: [], confirm: {}) {
            dismissals += 1
        }
        sut.presentStopConfirmation(request)
        sut.dismissPresentedSheet()

        // when
        sut.selection = .task("other")
        sut.taskStopSheetDidDismiss(requestID: request.id)

        // then
        #expect(dismissals == 0)
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
        given(listing).title(.any).willProduce { "Task \($0)" }
        given(listing).listError.willReturn(nil)
        given(listing).hasListedPublisher().willReturn(Just(true).eraseToAnyPublisher())
        given(listing).titlesPublisher().willReturn(Just<[String: String]>([:]).eraseToAnyPublisher())
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
