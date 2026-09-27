import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

@MainActor
extension TaskDetailVMTests {
    
    // MARK: - MS-DETAIL-4: actions
    
    @Test func givenBusyOrNoSessionID_whenRenderingActions_thenTakeOverIsDisabled() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let busySubject = harness.busySubject
        let detailBox = harness.detailBox
        let running = task(sessionID: "sess-1234567890")
        detailBox.value = running
        sut.didAppear()
        tasksSubject.send([running])
        await waitUntil { sut.task != nil }
        #expect(sut.canTakeover)
        
        // when — busy
        busySubject.send(["abc12345"])
        await waitUntil { !sut.canTakeover }
        #expect(!sut.canTakeover)
        
        // when — no session id
        busySubject.send([])
        let noSession = task(sessionID: nil)
        detailBox.value = noSession
        tasksSubject.send([noSession])
        
        // then
        await waitUntil { !sut.canTakeover }
        #expect(!sut.canTakeover)
    }
    
    @Test func givenARunningTask_whenRenderingActions_thenCancelIsShown() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let detailBox = harness.detailBox
        let running = task(status: "running")
        detailBox.value = running
        sut.didAppear()
        
        // when
        tasksSubject.send([running])
        
        // then
        await waitUntil { sut.canCancel }
        #expect(sut.canCancel)
        
        // when — settled
        let completed = task(status: "completed")
        detailBox.value = completed
        tasksSubject.send([completed])
        
        // then
        await waitUntil { !sut.canCancel }
        #expect(!sut.canCancel)
    }
    
    @Test func givenASubTask_whenRenderingTheHeader_thenAncestorBreadcrumbsAndOpenParentAppear() async {
        // given
        let harness = makeSUT(taskID: "child")
        let sut = harness.sut
        let useCase = harness.useCase
        let tasksSubject = harness.tasksSubject
        let detailBox = harness.detailBox
        let ancestorsBox = harness.ancestorsBox
        let parent = task(id: "parent")
        let child = task(id: "child", spawnedBy: "parent")
        detailBox.value = child
        ancestorsBox.value = [parent]
        given(useCase).task(.value("parent")).willReturn(parent)
        sut.didAppear()
        
        // when
        tasksSubject.send([parent, child])
        
        // then
        await waitUntil { !sut.ancestorCrumbs.isEmpty }
        #expect(sut.ancestorCrumbs.map(\.id) == ["parent"])
        #expect(sut.openParentTaskID == "parent")
    }
    
    @Test func givenAParentNotInTheListing_whenRenderingTheHeader_thenOpenParentIsHidden() async {
        // given — F4-38: "Open parent" only shows when the parent is actually listed.
        let harness = makeSUT(taskID: "child")
        let sut = harness.sut
        let useCase = harness.useCase
        let tasksSubject = harness.tasksSubject
        let detailBox = harness.detailBox
        let child = task(id: "child", spawnedBy: "parent")
        detailBox.value = child
        given(useCase).task(.value("parent")).willReturn(nil)
        sut.didAppear()
        
        // when
        tasksSubject.send([child])
        
        // then
        await waitUntil { sut.task != nil }
        // Positive setup first: the scenario really is "spawnedBy set but parent not listed", not a
        // VM that never recomputed at all.
        #expect(sut.task?.spawnedBy == "parent")
        #expect(sut.openParentTaskID == nil)
    }
    
    // MARK: - MS-DETAIL-5: message box submit
    
    @Test func givenAnEligibleMessage_whenSubmitted_thenTheFieldClearsImmediatelyRegardlessOfLaterOutcome() async {
        // given — a live-input running task: Send is eligible.
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        let tasksSubject = harness.tasksSubject
        let detailBox = harness.detailBox
        let running = task(status: "running", liveInput: true)
        detailBox.value = running
        sut.didAppear()
        tasksSubject.send([running])
        await waitUntil { sut.task != nil }
        
        // when
        let cleared = sut.submitMessage("  hello  ")
        
        // then — eligible, so the caller is told to clear the field immediately.
        #expect(cleared)
        await verify(useCase).send(.value("abc12345"), text: .value("hello")).calledEventually(1, before: .seconds(5))
    }
    
    @Test func givenAnEligibleResume_whenItSucceeds_thenItDispatchesButDoesNotNavigate() async {
        // given — a terminal task with a session: Continue (resume) is eligible. Monitor piece 7,
        // Design point 7: Continue no longer navigates — the conversation stays selected, and the
        // new turn appears once the listing refreshes and this VM's own membership recomputes.
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        let routing = harness.routing
        let tasksSubject = harness.tasksSubject
        let detailBox = harness.detailBox
        let done = task(status: "completed")
        detailBox.value = done
        sut.didAppear()
        tasksSubject.send([done])
        await waitUntil { sut.task != nil }

        // when
        let cleared = sut.submitMessage("follow up")

        // then
        #expect(cleared)
        await verify(useCase).resume(.value("abc12345"), text: .value("follow up"), onResumed: .any).calledEventually(1, before: .seconds(5))
        try? await Task.sleep(for: .milliseconds(50))
        verify(routing).selectTask(.any).called(0)
    }
    
    @Test func givenABlankOrIneligibleSubmit_whenSubmitted_thenTheTextIsKept() async {
        // given — a running task with no live input: neither Send nor Continue is eligible.
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        let tasksSubject = harness.tasksSubject
        let detailBox = harness.detailBox
        let running = task(status: "running", liveInput: false)
        detailBox.value = running
        sut.didAppear()
        tasksSubject.send([running])
        await waitUntil { sut.task != nil }
        // Positive setup first: the task really is running with no live input (genuinely
        // ineligible), not a VM that never recomputed `messageBoxModel` at all.
        #expect(sut.task?.status.isRunning == true)
        #expect(sut.messageBoxModel.canSend == false)
        #expect(sut.messageBoxModel.canContinue == false)
        
        // when / then — blank text is kept
        #expect(sut.submitMessage("   ") == false)
        // when / then — ineligible task state is kept
        #expect(sut.submitMessage("hello") == false)
        verify(useCase).send(.any, text: .any).called(0)
        verify(useCase).resume(.any, text: .any, onResumed: .any).called(0)
    }
    
    @Test func givenTheModelIsBusyForThisTask_whenRenderingTheMessageBox_thenTheButtonIsDisabled() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let busySubject = harness.busySubject
        let detailBox = harness.detailBox
        let running = task(status: "running", liveInput: true)
        detailBox.value = running
        sut.didAppear()
        tasksSubject.send([running])
        await waitUntil { sut.task != nil }
        #expect(!sut.messageBoxModel.isBusy)
        
        // when
        busySubject.send(["abc12345"])
        
        // then
        await waitUntil { sut.messageBoxModel.isBusy }
        #expect(sut.messageBoxModel.isBusy)
    }
    
    // MARK: - MS-DETAIL-6: unknown events
    
    @Test func givenAnUnknownEvent_whenBuildingTheTimeline_thenItAppearsOnlyInRawEvents() async {
        // given — the repository's `items(for:)`/`itemsPublisher` never include an unknown event
        // (`Timeline.items(from:)` drops it), while `events(for:)` (Raw Events) carries every line.
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let itemsSubject = harness.itemsSubject
        let detailBox = harness.detailBox
        let eventsBox = harness.eventsBox
        let running = task(status: "running")
        detailBox.value = running
        let unknownLine = #"{"v":1,"seq":1,"kind":"some_future_kind"}"#
        let unknownEvent = TaskEvent(line: unknownLine)!
        eventsBox.value = [unknownEvent]
        sut.didAppear()
        
        // when
        tasksSubject.send([running])
        itemsSubject.send([])
        
        // then
        await waitUntil { !sut.rawEvents.isEmpty }
        #expect(sut.rawEvents.count == 1)
        #expect(sut.rawEvents.first?.isUnknown == true)
        #expect(sut.timelineModel.rows.isEmpty)
    }
    
    // MARK: - Copy resume command (Monitor piece 3/3)

    @Test func givenASnapshotWithNoResumeCommand_whenRenderingActions_thenTheButtonIsHidden() async {
        // given — `resumeCommand` is read from the snapshot, not `detail(_:)`'s brief listing.
        let harness = makeSUT()
        let sut = harness.sut
        let running = task(status: "running")
        harness.detailBox.value = running
        harness.snapshotBox.value = running // no resume_command field
        sut.didAppear()

        // when
        harness.tasksSubject.send([running])
        await waitUntil { sut.task != nil }

        // then
        #expect(sut.resumeCommand == nil)
    }

    @Test func givenASnapshotWithAResumeCommand_whenRenderingActions_thenTheButtonIsShownWithTheExactString() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let running = task(status: "running")
        let command = "cd /repo && claude --resume sess-1234567890"
        harness.detailBox.value = running
        harness.snapshotBox.value = task(status: "running", resumeCommand: command)
        sut.didAppear()

        // when
        harness.tasksSubject.send([running])
        await waitUntil { sut.resumeCommand != nil }

        // then
        #expect(sut.resumeCommand == command)
    }

    @Test func givenARunningTask_whenRenderingTheCopyResumeCommandHelp_thenItWarnsAboutTwoWriters() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let running = task(status: "running")
        harness.detailBox.value = running
        harness.snapshotBox.value = task(status: "running", resumeCommand: "cd /repo && claude --resume s")
        sut.didAppear()

        // when
        harness.tasksSubject.send([running])
        await waitUntil { sut.resumeCommand != nil }

        // then
        #expect(sut.copyResumeCommandHelp.contains("two writers on one conversation"))
    }

    @Test func givenAFinishedTask_whenRenderingTheCopyResumeCommandHelp_thenItHasNoWarning() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let done = task(status: "completed")
        harness.detailBox.value = done
        harness.snapshotBox.value = task(status: "completed", resumeCommand: "cd /repo && claude --resume s")
        sut.didAppear()

        // when
        harness.tasksSubject.send([done])
        await waitUntil { sut.resumeCommand != nil }

        // then
        #expect(sut.copyResumeCommandHelp == "Copies a command that resumes this session in your own terminal.")
        #expect(!sut.copyResumeCommandHelp.contains("two writers"))
    }

    @Test func givenACopySucceedsOnAFinishedTask_whenTapped_thenTheOutcomeIsRecordedThroughSetOutcome() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        let routing = harness.routing
        let command = "cd /repo && claude --resume s"
        let done = task(status: "completed")
        harness.detailBox.value = done
        harness.snapshotBox.value = task(status: "completed", resumeCommand: command)
        given(routing).copyToPasteboard(.value(command)).willReturn(true)
        sut.didAppear()
        harness.tasksSubject.send([done])
        await waitUntil { sut.resumeCommand != nil }

        // when
        sut.didTapCopyResumeCommand()

        // then
        await verify(routing).copyToPasteboard(.value(command)).calledEventually(1, before: .seconds(5))
        await verify(useCase).setOutcome(.value("abc12345"), .value("Copied resume command.")).calledEventually(1, before: .seconds(5))
    }

    @Test func givenACopySucceedsOnARunningTask_whenTapped_thenTheOutcomeWarnsAboutTwoWriters() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        let routing = harness.routing
        let running = task(status: "running")
        let command = "cd /repo && claude --resume s"
        harness.detailBox.value = running
        harness.snapshotBox.value = task(status: "running", resumeCommand: command)
        given(routing).copyToPasteboard(.value(command)).willReturn(true)
        sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { sut.resumeCommand != nil }

        // when
        sut.didTapCopyResumeCommand()

        // then
        let expected = "Copied. This task is still running — resuming it now would put two writers "
        + "on one conversation; prefer Take over."
        await verify(useCase).setOutcome(.value("abc12345"), .value(expected)).calledEventually(1, before: .seconds(5))
    }

    @Test func givenTheCopyFails_whenTapped_thenTheOutcomeSaysSo() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        let routing = harness.routing
        let command = "cd /repo && claude --resume s"
        let done = task(status: "completed")
        harness.detailBox.value = done
        harness.snapshotBox.value = task(status: "completed", resumeCommand: command)
        given(routing).copyToPasteboard(.value(command)).willReturn(false)
        sut.didAppear()
        harness.tasksSubject.send([done])
        await waitUntil { sut.resumeCommand != nil }

        // when
        sut.didTapCopyResumeCommand()

        // then
        await verify(useCase).setOutcome(.value("abc12345"), .value("Couldn't copy to the clipboard.")).calledEventually(1, before: .seconds(5))
    }

    @Test func givenNoResumeCommand_whenTapped_thenNothingIsCopiedOrRecorded() async {
        // given — the button is hidden in this state, but the action itself is defensive too.
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        let routing = harness.routing
        let done = task(status: "completed")
        harness.detailBox.value = done
        harness.snapshotBox.value = done // no resume_command
        sut.didAppear()
        harness.tasksSubject.send([done])
        await waitUntil { sut.task != nil }
        #expect(sut.resumeCommand == nil)

        // when
        sut.didTapCopyResumeCommand()

        // then
        verify(routing).copyToPasteboard(.any).called(0)
        verify(useCase).setOutcome(.any, .any).called(0)
    }

    @Test func givenACopyOutcome_whenTheSnapshotRecomputesOrTheScreenIsRevisited_thenItSurvives() async {
        // given — `setOutcome` writes through `TaskActionRepository`'s durable channel; the VM only
        // ever reflects it back via `outcomesPublisher()` (never storing it only in
        // `outcomeMessage`), so a later recompute or a leave/revisit must not lose it. The
        // repository echoing the write back through the same publisher it is a stand-in for here —
        // re-stubbing `setOutcome` with a second matcher would be FIFO/unreliable (see this file's
        // sibling suites' notes), so the publish is driven directly instead.
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        let routing = harness.routing
        let command = "cd /repo && claude --resume s"
        let done = task(status: "completed")
        harness.detailBox.value = done
        harness.snapshotBox.value = task(status: "completed", resumeCommand: command)
        given(routing).copyToPasteboard(.value(command)).willReturn(true)
        sut.didAppear()
        harness.tasksSubject.send([done])
        await waitUntil { sut.resumeCommand != nil }

        // when — the copy calls the durable channel...
        sut.didTapCopyResumeCommand()
        await verify(useCase).setOutcome(.value("abc12345"), .value("Copied resume command.")).calledEventually(1, before: .seconds(5))
        // ...which the repository echoes back through `outcomesPublisher()`.
        harness.outcomesSubject.send(["abc12345": "Copied resume command."])
        await waitUntil { sut.outcomeMessage == "Copied resume command." }

        // then — an unrelated recompute (another listing push) does not clear it
        harness.tasksSubject.send([done])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(sut.outcomeMessage == "Copied resume command.")

        // and — navigating away and back builds a *fresh* VM (the coordinator makes a new one per
        // task), which must pick the stored outcome up from the repository's replay alone: nothing
        // is re-sent here, so this fails if a new subscriber stopped receiving stored outcomes.
        sut.didDisappear()
        let fresh = TaskDetailVM(taskID: "abc12345", useCase: useCase, routing: routing)
        fresh.didAppear()
        harness.tasksSubject.send([done])
        await waitUntil { fresh.outcomeMessage != nil }
        #expect(fresh.outcomeMessage == "Copied resume command.")
    }

    // MARK: - Teardown (root AGENTS.md rule 7)
    
    @Test func givenDidDisappear_whenCalled_thenTheLeaseIsReleasedAndReappearingReacquiresIt() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        let lease = harness.lease
        let tasksSubject = harness.tasksSubject
        let detailBox = harness.detailBox
        let snapshotBox = harness.snapshotBox
        let running = task(status: "running")
        detailBox.value = running
        snapshotBox.value = running
        sut.didAppear()
        tasksSubject.send([running])
        await waitUntil { sut.task != nil }

        // when
        sut.didDisappear()

        // then
        verify(lease).release().called(1)

        // when — reappearing resubscribes and reacquires the lease
        sut.didAppear()
        tasksSubject.send([running])

        // then
        await waitUntil { sut.task != nil }
        verify(useCase).acquireEventLease(.value("abc12345")).called(2)
    }

}
