import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbCommon
import PbTestUtilities
import Testing

/// A confirmation dialog stays open while the listing keeps updating underneath it (PR #1 review):
/// confirming must act on the group/conversation as it is NOW, never on what it was when the dialog
/// opened. Split out of `ParallelVMTests.swift` to keep that file under the length limit.
@MainActor
extension ParallelVMTests {

    @Test func givenAMemberJoinsWhileCancelAllIsOpen_whenConfirmed_thenTheNewMemberIsCancelledToo() async {
        // given — one running member, and the cancel-all dialog open
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        let tasksSubject = harness.tasksSubject
        let tasksBox = harness.tasksBox
        let first = task(id: "t1", status: "running")
        tasksBox.value["t1"] = first
        sut.didAppear()
        tasksSubject.send([first])
        await waitUntil { sut.canCancelAll }
        var capturedEvent: ViewEvent?
        let cancellable = sut.objectDidPublishViewEvent.publisher.sink { capturedEvent = $0 }
        sut.didTapCancelAll()
        await waitUntil { capturedEvent?.dialog != nil }
        guard case .dialog(let dialog) = capturedEvent else {
            Issue.record("expected a .dialog event")
            cancellable.cancel()
            return
        }

        // when — an independent new root joins the group before the person confirms
        let joined = task(id: "t2", status: "running")
        tasksBox.value["t2"] = joined
        tasksSubject.send([first, joined])
        await waitUntil { sut.columns.count == 2 }
        dialog.actions.first?.action()

        // then — the member that joined is cancelled as well, not just the captured snapshot
        await verify(useCase).cancelAll(.matching { Set($0) == ["t1", "t2"] }).calledEventually(1, before: .seconds(5))
        cancellable.cancel()
    }

    @Test func givenAConversationIsResumedWhileCancelAllIsOpen_whenConfirmed_thenTheResumedTurnIsCancelled() async {
        // given — one running member, and the cancel-all dialog open
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        let tasksSubject = harness.tasksSubject
        let tasksBox = harness.tasksBox
        let start = Date.now.addingTimeInterval(-300)
        let firstTurn = task(id: "t1", status: "running", startedAt: start)
        tasksBox.value["t1"] = firstTurn
        sut.didAppear()
        tasksSubject.send([firstTurn])
        await waitUntil { sut.canCancelAll }
        var capturedEvent: ViewEvent?
        let cancellable = sut.objectDidPublishViewEvent.publisher.sink { capturedEvent = $0 }
        sut.didTapCancelAll()
        await waitUntil { capturedEvent?.dialog != nil }
        guard case .dialog(let dialog) = capturedEvent else {
            Issue.record("expected a .dialog event")
            cancellable.cancel()
            return
        }

        // when — the first turn finishes and is resumed (a `parent_task_id` link, which
        // `runningInSubtrees` never follows) before the person confirms
        let finished = task(id: "t1", status: "completed", startedAt: start)
        let resumed = task(id: "t2", status: "running", startedAt: start.addingTimeInterval(100), parentTaskID: "t1")
        tasksBox.value["t1"] = finished
        tasksBox.value["t2"] = resumed
        tasksSubject.send([finished, resumed])
        await waitUntil { sut.columns.first?.task.taskID == "t2" }
        dialog.actions.first?.action()

        // then — the resumed turn is part of what gets cancelled
        await verify(useCase).cancelAll(.matching { $0.contains("t2") }).calledEventually(1, before: .seconds(5))
        cancellable.cancel()
    }

    @Test func givenTheConversationIsResumedWhileTakeoverIsOpen_whenConfirmed_thenItRefusesInsteadOfTakingOver() async {
        // given — a finished conversation and its "Continue in terminal" dialog open
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        let routing = harness.routing
        let tasksSubject = harness.tasksSubject
        let tasksBox = harness.tasksBox
        let start = Date.now.addingTimeInterval(-300)
        let firstTurn = task(id: "t1", status: "completed", startedAt: start)
        tasksBox.value["t1"] = firstTurn
        sut.didAppear()
        tasksSubject.send([firstTurn])
        await waitUntil { sut.columns.count == 1 }
        var capturedEvent: ViewEvent?
        let cancellable = sut.objectDidPublishViewEvent.publisher.sink { capturedEvent = $0 }
        sut.columns.first?.onTapTakeover()
        await waitUntil { capturedEvent?.dialog != nil }
        guard case .dialog(let dialog) = capturedEvent else {
            Issue.record("expected a .dialog event")
            cancellable.cancel()
            return
        }

        // when — the conversation is resumed before the person confirms, so its column now shows t2
        let resumed = task(id: "t2", status: "running", startedAt: start.addingTimeInterval(100), parentTaskID: "t1")
        tasksBox.value["t2"] = resumed
        tasksSubject.send([firstTurn, resumed])
        await waitUntil { sut.columns.first?.task.taskID == "t2" }
        dialog.actions.first?.action()

        // then — no takeover of the stale member, no navigation, and the column says why
        verify(useCase).beginTakeover(taskID: .any).called(0)
        verify(routing).selectTask(.any).called(0)
        verify(useCase).setOutcome(.value("t2"), .value("The conversation moved on — review and try again.")).called(1)
        cancellable.cancel()
    }
}
