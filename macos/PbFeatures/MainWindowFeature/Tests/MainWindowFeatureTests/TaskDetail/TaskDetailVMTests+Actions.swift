import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbTerminal
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
        await verify(useCase).send(.value("abc12345"), text: .value("hello")).calledEventually(1, before: .seconds(1))
    }
    
    @Test func givenAnEligibleResume_whenItSucceeds_thenItRoutesToTheNewTask() async {
        // given — a terminal task with a session: Continue (resume) is eligible.
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
        await verify(useCase).resume(.value("abc12345"), text: .value("follow up"), onResumed: .any).calledEventually(1, before: .seconds(1))
        await verify(routing).selectTask(.value("newTaskID")).calledEventually(1, before: .seconds(1))
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
        #expect(sut.timelineModel.items.isEmpty)
    }
    
    // MARK: - Teardown (root AGENTS.md rule 7)
    
    @Test func givenDidDisappear_whenCalled_thenTheLeaseAndGitPollAreReleasedAndReappearingReacquiresThem() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        let tasksSubject = harness.tasksSubject
        let detailBox = harness.detailBox
        let snapshotBox = harness.snapshotBox
        let scheduleBox = harness.scheduleBox
        let cancelledSchedules = harness.cancelledSchedules
        let running = task(status: "running")
        detailBox.value = running
        snapshotBox.value = running
        sut.didAppear()
        tasksSubject.send([running])
        await waitUntil { scheduleBox.value != nil }
        let releasedBefore = cancelledSchedules.value
        
        // when
        sut.didDisappear()
        
        // then
        #expect(cancelledSchedules.value > releasedBefore)
        
        // when — reappearing resubscribes and reacquires the lease
        scheduleBox.value = nil
        sut.didAppear()
        tasksSubject.send([running])
        
        // then
        await waitUntil { scheduleBox.value != nil }
        #expect(scheduleBox.value != nil)
        verify(useCase).acquireEventLease(.value("abc12345")).called(2)
    }
    
}
