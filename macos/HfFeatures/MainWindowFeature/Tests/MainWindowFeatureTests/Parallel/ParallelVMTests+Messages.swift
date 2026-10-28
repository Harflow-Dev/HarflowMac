import Foundation
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - ParallelVM messages

@MainActor
extension ParallelVMTests {
    @Test(arguments: [false, true])
    func givenConversationWithContinuation_whenColumnSends_thenCurrentMemberReceivesExactText(now: Bool) async throws {
        // given
        let harness = makeSUT()
        let first = task(id: "first", status: "completed", startedAt: .now.addingTimeInterval(-30))
        let current = task(id: "current", startedAt: .now, parentTaskID: "first")
        harness.tasksBox.value = ["first": first]
        given(harness.useCase).sendMessage(.any, text: .any, now: .any).willReturn()
        harness.sut.didAppear()
        harness.tasksSubject.send([first])
        await waitUntil { harness.sut.columns.count == 1 }
        let column = try #require(harness.sut.columns.first)
        // when — even a previously captured column action resolves the latest conversation member at click time.
        harness.tasksBox.value = ["first": first, "current": current]
        harness.tasksSubject.send([first, current])
        await waitUntil { harness.sut.columns.first?.task.taskID == "current" }
        #expect(column.onSubmitMessage?("  exact\ntext  ", now) == true)
        // then
        await verify(harness.useCase)
.sendMessage(.value("current"), text: .value("  exact\ntext  "), now: .value(now))
            .calledEventually(1, before: .seconds(5))
        harness.sut.didDisappear()
    }

    @Test func givenColumnWithOutstandingAction_whenSubmittedTwice_thenOnlyFirstDispatchIsAccepted() async throws {
        // given
        let harness = makeSUT()
        let current = task(id: "current")
        harness.tasksBox.value = ["current": current]
        given(harness.useCase).sendMessage(.any, text: .any, now: .any).willReturn()
        harness.sut.didAppear()
        harness.tasksSubject.send([current])
        await waitUntil { harness.sut.columns.count == 1 }
        let column = try #require(harness.sut.columns.first)
        // when / then — the synchronous admission guard covers the publication delay.
        #expect(column.onSubmitMessage?("first", false) == true)
        #expect(column.onSubmitMessage?("second", true) == false)
        await verify(harness.useCase)
.sendMessage(.value("current"), text: .value("first"), now: .value(false))
            .calledEventually(1, before: .seconds(5))
        verify(harness.useCase).sendMessage(.any, text: .value("second"), now: .any).called(0)
        harness.sut.didDisappear()
    }

    @Test func givenTakenOverOrBusyColumn_whenSubmitting_thenDraftRemainsAndNothingIsDispatched() async throws {
        // given
        let harness = makeSUT()
        var raw = task(id: "current").raw
        raw["taken_over"] = .bool(true)
        let current = try #require(TaskInfo(.object(raw)))
        harness.tasksBox.value = ["current": current]
        harness.sut.didAppear()
        harness.tasksSubject.send([current])
        await waitUntil { harness.sut.columns.count == 1 }
        // when / then
        #expect(harness.sut.columns.first?.onSubmitMessage?("keep", true) == false)
        raw["taken_over"] = .bool(false)
        let ordinary = try #require(TaskInfo(.object(raw)))
        harness.tasksBox.value = ["current": ordinary]
        harness.tasksSubject.send([ordinary])
        harness.busySubject.send(["current"])
        await waitUntil { harness.sut.columns.first?.isBusy == true }
        #expect(harness.sut.columns.first?.onSubmitMessage?("keep", false) == false)
        verify(harness.useCase).sendMessage(.any, text: .any, now: .any).called(0)
        harness.sut.didDisappear()
    }

    @Test func givenWorkflowNodeColumn_whenCancellingQueuedMessage_thenExactTaskAndMessageAreRouted() async throws {
        // given
        let harness = makeSUT()
        var raw = task(id: "node").raw
        raw["workflow_run_id"] = .string("workflow")
        let node = try #require(TaskInfo(.object(raw)))
        harness.tasksBox.value = ["node": node]
        given(harness.useCase).cancelMessage(.any, messageID: .any).willReturn()
        harness.sut.setWorkflowTaskIDs(["node"])
        harness.sut.didAppear()
        harness.tasksSubject.send([node])
        await waitUntil { harness.sut.columns.count == 1 }
        // when
        harness.sut.columns.first?.onCancelMessage?("message-1")
        // then
        await verify(harness.useCase)
.cancelMessage(.value("node"), messageID: .value("message-1"))
            .calledEventually(1, before: .seconds(5))
        harness.sut.didDisappear()
    }

    @Test func givenUnsupportedEngine_whenColumnDispatchFails_thenOutcomePreservesSpecificCapabilityReason() async {
        // given
        let harness = makeSUT()
        let current = task(id: "current")
        harness.tasksBox.value = ["current": current]
        let refusal = ToolError.unsupportedCommand(tool: "harflow-ctl", command: "send", detail: "Missing capability messaging.v1")
        given(harness.useCase).sendMessage(.any, text: .any, now: .any).willThrow(refusal)
        harness.sut.didAppear()
        harness.tasksSubject.send([current])
        await waitUntil { harness.sut.columns.count == 1 }
        // when
        #expect(harness.sut.columns.first?.onSubmitMessage?("check", true) == true)
        // then
        await verify(harness.useCase)
.setOutcome(.value("current"), .value("Couldn't send the message: \(refusal.message)"))
            .calledEventually(1, before: .seconds(5))
        harness.sut.didDisappear()
    }

    @Test func givenUnchangedActivity_whenOnlyMessageLedgerUpdates_thenColumnEqualityPublishesTheNewQueue() async throws {
        // given
        let harness = makeSUT()
        let current = task(id: "current")
        harness.tasksBox.value = ["current": current]
        harness.sut.didAppear()
        harness.tasksSubject.send([current])
        await waitUntil { harness.sut.columns.count == 1 }
        let previous = try #require(harness.sut.columns.first).renderValue
        var raw = current.raw
        raw["messages"] = .array([.object(["id": .string("queued-1"), "status": .string("queued"), "text": .string("Review it")])])
        let snapshot = try #require(TaskInfo(.object(raw)))
        // when
        harness.snapshotsSubject.send(["current": snapshot])
        await waitUntil { harness.sut.columns.first?.task.raw["messages"] != nil }
        // then
        let refreshed = try #require(harness.sut.columns.first)
        #expect(refreshed.renderValue != previous)
        #expect(WorkMessageQueue.items(raw: refreshed.task.raw).first?.id == "queued-1")
        harness.sut.didDisappear()
    }
}
