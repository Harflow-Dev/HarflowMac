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
    
    // MARK: - Item m: the cancel confirmation dialog
    
    @Test func givenDidTapCancel_whenPublished_thenTheDialogMatchesTheExactCopyAndDestructiveRole() async {
        // given
        let harness = makeSUT()
        let running = task(status: "running")
        harness.detailBox.value = running
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.task != nil }
        var capturedEvent: ViewEvent?
        let cancellable = harness.sut.objectDidPublishViewEvent.publisher.sink { capturedEvent = $0 }
        
        // when
        harness.sut.didTapCancel()
        
        // then
        await waitUntil { capturedEvent?.dialog != nil }
        guard case .dialog(let dialog) = capturedEvent else {
            Issue.record("expected a .dialog event")
            cancellable.cancel()
            return
        }
        #expect(dialog.title == "Cancel this task?")
        #expect(dialog.description == "polybridge stops the run and, best-effort, every live sub-task it started.")
        #expect(dialog.actions.count == 1)
        #expect(dialog.actions.first?.title == "Cancel task and its sub-tasks")
        #expect(dialog.actions.first?.role == .destructive)
        
        dialog.actions.first?.action()
        await verify(harness.useCase).cancel(.value("abc12345")).calledEventually(1, before: .seconds(5))
        cancellable.cancel()
    }
    
    // MARK: - Item n: the takeover dialog (always Terminal.app — the Monitor's only destination)

    @Test func givenARunningTask_whenTappingTakeover_thenTheDialogOffersToStopAndTakeOver() async {
        // given
        let harness = makeSUT()
        let running = task(status: "running", freedom: "read_only")
        harness.detailBox.value = running
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.task != nil }
        var capturedEvent: ViewEvent?
        let cancellable = harness.sut.objectDidPublishViewEvent.publisher.sink { capturedEvent = $0 }

        // when
        harness.sut.didTapTakeover()

        // then
        await waitUntil { capturedEvent?.dialog != nil }
        guard case .dialog(let dialog) = capturedEvent else {
            Issue.record("expected a .dialog event")
            cancellable.cancel()
            return
        }
        #expect(dialog.title == "Take over this task?")
        #expect(dialog.actions.count == 2)
        #expect(dialog.actions.first?.title == "Stop it and take over")
        #expect(dialog.actions.first?.role == nil)
        #expect(dialog.actions.last?.title == "Cancel")
        #expect(dialog.actions.last?.role == .cancel) // the original had an explicit Cancel button
        #expect(dialog.description?.contains("Terminal.app") == true)
        #expect(
            dialog.description
            == "The headless run is stopped first (with any sub-tasks), then the same conversation opens in Terminal.app. It runs under your own"
            + " default permissions, not this task's read_only level. While the terminal is open, polybridge refuses resumes of this session from"
            + " anywhere else."
        )

        dialog.actions.first?.action()
        await verify(harness.useCase).beginTakeover(taskID: .value("abc12345")).calledEventually(1, before: .seconds(5))
        cancellable.cancel()
    }

    @Test func givenATerminalTask_whenTappingTakeover_thenTheDialogOffersToContinueInATerminal() async {
        // given
        let harness = makeSUT()
        let done = task(status: "completed", freedom: "read_only")
        harness.detailBox.value = done
        harness.sut.didAppear()
        harness.tasksSubject.send([done])
        await waitUntil { harness.sut.task != nil }
        var capturedEvent: ViewEvent?
        let cancellable = harness.sut.objectDidPublishViewEvent.publisher.sink { capturedEvent = $0 }

        // when
        harness.sut.didTapTakeover()

        // then
        await waitUntil { capturedEvent?.dialog != nil }
        guard case .dialog(let dialog) = capturedEvent else {
            Issue.record("expected a .dialog event")
            cancellable.cancel()
            return
        }
        #expect(dialog.title == "Continue this session in a terminal?")
        #expect(dialog.actions.first?.title == "Continue in terminal")
        #expect(
            dialog.description
            == "The same conversation opens in Terminal.app. It runs under your own default permissions, not this task's read_only level. While the"
            + " terminal is open, polybridge refuses resumes of this session from anywhere else."
        )

        dialog.actions.first?.action()
        await verify(harness.useCase).beginTakeover(taskID: .value("abc12345")).calledEventually(1, before: .seconds(5))
        cancellable.cancel()
    }

    @Test func givenARunningTask_whenRenderingTheTakeoverButton_thenTheLabelIsTakeOver() async {
        // given
        let harness = makeSUT()
        let running = task(status: "running")
        harness.detailBox.value = running
        harness.sut.didAppear()

        // when
        harness.tasksSubject.send([running])

        // then
        await waitUntil { harness.sut.task != nil }
        #expect(harness.sut.takeoverButtonLabel == "Take over")
    }

    @Test func givenAFinishedTask_whenRenderingTheTakeoverButton_thenTheLabelIsContinueInTerminal() async {
        // given
        let harness = makeSUT()
        let done = task(status: "completed")
        harness.detailBox.value = done
        harness.sut.didAppear()

        // when
        harness.tasksSubject.send([done])

        // then
        await waitUntil { harness.sut.task != nil }
        #expect(harness.sut.takeoverButtonLabel == "Continue in terminal")
    }
    
    // MARK: - Item o: the outcome line's colour rule
    
    @Test func givenAnOutcomeMessage_whenItStartsWithRefused_thenTheHeaderColorIsRedOtherwiseSecondary() async {
        // given
        let harness = makeSUT()
        let running = task(status: "running")
        harness.detailBox.value = running
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.task != nil }
        
        // when
        harness.outcomesSubject.send(["abc12345": "Refused: another run or takeover is using this session."])
        
        // then
        await waitUntil { harness.sut.outcomeMessage != nil }
        #expect(harness.sut.outcomeMessage == "Refused: another run or takeover is using this session.")
        #expect(OutcomeColor.of(harness.sut.outcomeMessage!) == .failedRed)
        
        // when — a non-refusal outcome
        harness.outcomesSubject.send(["abc12345": "Follow-up sent — the reply will appear below."])

        // then
        await waitUntil { harness.sut.outcomeMessage == "Follow-up sent — the reply will appear below." }
        #expect(OutcomeColor.of(harness.sut.outcomeMessage!) == .secondary)
    }
    
    // MARK: - Item p: the Summary tab's final answer falls back to task.summary

    @Test func givenATerminalTask_whenComputingTheFinalAnswer_thenTheSnapshotWinsAndTheTaskListingIsTheFallback() async {
        // given — no snapshot summary yet, so the task listing's own summary is used
        let harness = makeSUT()
        let done = task(status: "completed", summary: "from the task listing")
        harness.detailBox.value = done
        harness.snapshotBox.value = nil
        harness.sut.didAppear()
        harness.tasksSubject.send([done])
        await waitUntil { harness.sut.task != nil }
        // Summary only recomputes while shown (Monitor piece 8, Codex review round 2, finding 2).
        harness.sut.didSelectTab(.summary)
        #expect(harness.sut.summaryModel.finalAnswer == "from the task listing")

        // when — a snapshot with its own summary becomes available
        harness.snapshotBox.value = task(status: "completed", summary: "from the snapshot")
        harness.tasksSubject.send([done])

        // then — the snapshot's summary wins
        await waitUntil { harness.sut.summaryModel.finalAnswer == "from the snapshot" }
        #expect(harness.sut.summaryModel.finalAnswer == "from the snapshot")
    }
    
    // MARK: - Item r: Inspector details come from the snapshot
    
    @Test func givenASnapshotDiffersFromTheListing_whenBuildingTheInspector_thenDetailsComeFromTheSnapshot() async {
        // given
        let harness = makeSUT()
        let listing = task(status: "running")
        let snapshot = task(status: "running", enforcement: ["os_enforced": .bool(true)])
        harness.detailBox.value = listing
        harness.snapshotBox.value = snapshot
        
        // when
        harness.sut.didAppear()
        harness.tasksSubject.send([listing])
        
        // then — `listing` (`detailBox`) never carries `enforcement`, so a non-nil value here can
        // only have come from the snapshot (`recomputeInspector`'s `detail: snapshot ?? task`).
        await waitUntil { harness.sut.inspectorModel != nil }
        #expect(harness.sut.inspectorModel?.detail.enforcement != nil)
        #expect(harness.sut.inspectorModel?.hasSnapshot == true)
    }
    
    // MARK: - Item t: resume still completes even after the VM is released

    @Test func givenResumeSucceeds_whenTheVMIsReleasedBeforeItCompletes_thenTheDispatchStillCompletes() async {
        // given — Monitor piece 7, Design point 7: Continue no longer navigates, so this no longer
        // checks routing; it still must check that releasing the VM right after submit does not
        // cancel the in-flight resume (`submitMessage`'s resume branch captures `useCase` strongly,
        // never `self`).
        weak var weakSUT: TaskDetailVM?
        var capturedUseCase: MockTaskDetailUseCase!
        do {
            let harness = makeSUT()
            weakSUT = harness.sut
            capturedUseCase = harness.useCase
            let done = task(status: "completed")
            harness.detailBox.value = done
            harness.sut.didAppear()
            harness.tasksSubject.send([done])
            await waitUntil { harness.sut.task != nil }

            // when — submit while the VM is still alive.
            #expect(harness.sut.submitMessage("follow up"))
        }

        // then — nothing above kept `sut` alive, yet the resume dispatch still completes.
        #expect(weakSUT == nil)
        await verify(capturedUseCase).resume(.value("abc12345"), text: .value("follow up"), onResumed: .any).calledEventually(1, before: .seconds(5))
    }
    
    // MARK: - Item u: sub-task strip and "Open parent" routing
    
    @Test func givenASubTaskStripTap_whenInvoked_thenItRoutesToTheSubTask() async {
        // given
        let harness = makeSUT()
        let running = task(status: "running")
        let child = task(id: "child1", spawnedBy: "abc12345")
        harness.detailBox.value = running
        harness.childrenBox.value = [child]
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.timelineModel.subTaskStrip != nil }
        
        // when — the strip's `onSelectTask` closure is wired to `didTapTask`
        harness.sut.timelineModel.subTaskStrip?.onSelectTask("child1")
        
        // then
        verify(harness.routing).selectTask(.value("child1")).called(1)
    }
    
    @Test func givenOpenParentIsTapped_whenInvoked_thenItRoutesToTheParent() async {
        // given
        let harness = makeSUT(taskID: "child")
        let parent = task(id: "parent")
        let child = task(id: "child", spawnedBy: "parent")
        harness.detailBox.value = child
        harness.ancestorsBox.value = [parent]
        given(harness.useCase).task(.value("parent")).willReturn(parent)
        harness.sut.didAppear()
        harness.tasksSubject.send([parent, child])
        await waitUntil { harness.sut.openParentTaskID == "parent" }
        
        // when — `TaskDetailView.swift`'s `Button("Open parent") { viewModel.didTapTask(parentID) }`
        harness.sut.didTapTask(harness.sut.openParentTaskID!)
        
        // then
        verify(harness.routing).selectTask(.value("parent")).called(1)
    }
}
