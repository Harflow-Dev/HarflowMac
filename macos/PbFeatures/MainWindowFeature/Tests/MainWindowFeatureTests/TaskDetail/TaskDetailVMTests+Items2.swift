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
    
    // MARK: - Item i: a non-running task does not poll
    
    @Test func givenATaskThatStartsNonRunning_whenGitLoads_thenNoPollIsEverScheduled() async {
        // given
        let harness = makeSUT()
        let done = task(status: "completed")
        harness.detailBox.value = done
        harness.snapshotBox.value = done
        let expected = GitChanges(files: [], diffs: [], commitsSinceBase: nil, branch: "once", labels: [], comparedWithBase: true)
        harness.gitChangesEffect.value = { expected }
        
        // when
        harness.sut.didAppear()
        harness.tasksSubject.send([done])
        
        // then — the one-shot load still happens…
        await waitUntil { harness.sut.changes?.branch == "once" }
        #expect(harness.sut.changes?.branch == "once")
        // …but no poll is ever scheduled, because the task never was running.
        verify(harness.useCase).schedule(after: .any, execute: .any).called(0)
    }
    
    // MARK: - Items j + l: changesError resets only on success; stale changes survive a failure
    
    @Test func givenAFailedReload_whenStaleChangesExist_thenTheyAreKeptAndTheBaselineErrorCopyShowsOnlyOnFailure() async {
        // given — an initial successful load
        let harness = makeSUT()
        let running = task(status: "running")
        harness.detailBox.value = running
        harness.snapshotBox.value = running
        let success = GitChanges(files: [], diffs: [], commitsSinceBase: nil, branch: "main", labels: [], comparedWithBase: true)
        harness.gitChangesEffect.value = { success }
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.changes?.branch == "main" }
        #expect(harness.sut.changesError == nil)
        
        // when — the snapshot becomes unavailable (`polybridge-ctl status` failing) and a reload runs
        harness.snapshotBox.value = nil
        await harness.sut.loadChanges()
        
        // then — the stale changes are kept, never cleared on failure, and the exact baseline-error
        // copy is shown
        #expect(harness.sut.changes?.branch == "main")
        #expect(harness.sut.changesError == "The task's baseline could not be read (polybridge-ctl status failed), so its changes are not shown.")
        
        // when — the snapshot is available again and the reload succeeds
        harness.snapshotBox.value = running
        let refreshed = GitChanges(files: [], diffs: [], commitsSinceBase: nil, branch: "refreshed", labels: [], comparedWithBase: true)
        harness.gitChangesEffect.value = { refreshed }
        await harness.sut.loadChanges()
        
        // then — the error resets only now, on success
        #expect(harness.sut.changesError == nil)
        #expect(harness.sut.changes?.branch == "refreshed")
    }
    
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
        await verify(harness.useCase).cancel(.value("abc12345")).calledEventually(1, before: .seconds(1))
        cancellable.cancel()
    }
    
    // MARK: - Item n: the takeover dialog
    
    @Test func givenARunningTask_whenSelectingTakeoverDestination_thenTheDialogOffersToStopAndTakeOver() async {
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
        harness.sut.didSelectTakeoverDestination(.embedded)
        
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
        #expect(
            dialog.description
            == "The headless run is stopped first (with any sub-tasks), then the same conversation opens in a terminal. It runs under your own"
            + " default permissions, not this task's read_only level. While the terminal is open, polybridge refuses resumes of this session from"
            + " anywhere else."
        )
        
        dialog.actions.first?.action()
        await verify(harness.useCase).beginTakeover(taskID: .value("abc12345"), destination: .any).calledEventually(1, before: .seconds(1))
        cancellable.cancel()
    }
    
    @Test func givenATerminalTask_whenSelectingTakeoverDestination_thenTheDialogOffersToContinueInATerminal() async {
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
        harness.sut.didSelectTakeoverDestination(.terminalApp)
        
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
            == "The same conversation opens in a terminal. It runs under your own default permissions, not this task's read_only level. While the"
            + " terminal is open, polybridge refuses resumes of this session from anywhere else."
        )
        
        dialog.actions.first?.action()
        await verify(harness.useCase).beginTakeover(taskID: .value("abc12345"), destination: .any).calledEventually(1, before: .seconds(1))
        cancellable.cancel()
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
        harness.outcomesSubject.send(["abc12345": "Continued as task def456."])
        
        // then
        await waitUntil { harness.sut.outcomeMessage == "Continued as task def456." }
        #expect(OutcomeColor.of(harness.sut.outcomeMessage!) == .secondary)
    }
    
    // MARK: - Item p: the Changes summary falls back to task.summary
    
    @Test func givenATerminalTask_whenComputingTheChangesSummary_thenTheSnapshotWinsAndTheTaskListingIsTheFallback() async {
        // given — no snapshot summary yet, so the task listing's own summary is used
        let harness = makeSUT()
        let done = task(status: "completed", summary: "from the task listing")
        harness.detailBox.value = done
        harness.snapshotBox.value = nil
        harness.sut.didAppear()
        harness.tasksSubject.send([done])
        await waitUntil { harness.sut.task != nil }
        #expect(harness.sut.changesModel.summary == "from the task listing")
        
        // when — a snapshot with its own summary becomes available
        harness.snapshotBox.value = task(status: "completed", summary: "from the snapshot")
        harness.tasksSubject.send([done])
        
        // then — the snapshot's summary wins
        await waitUntil { harness.sut.changesModel.summary == "from the snapshot" }
        #expect(harness.sut.changesModel.summary == "from the snapshot")
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
    
    // Regression (item 3): the original had both panes read the same `changes` — a git result must
    // refresh the Inspector too, not only `changesModel`/`changesFileCount`. `loadChanges()` (the
    // poll, or a manual reload) runs outside `recompute()`, so this only holds if `loadChanges()`
    // rebuilds the Inspector itself rather than relying on the next full `recompute()` pass.
    @Test func givenAGitResultOutsideAFullRecompute_whenItLands_thenTheInspectorIsRebuiltToo() async {
        // given — the initial `recompute()` pass already populates the Inspector with the first
        // git result, so the positive baseline below proves the Inspector really was wired to
        // `changes` at all before checking that a LATER, out-of-band result also reaches it.
        let harness = makeSUT()
        let running = task(status: "running")
        harness.detailBox.value = running
        harness.snapshotBox.value = running
        let initial = GitChanges(files: [], diffs: [], commitsSinceBase: nil, branch: "initial", labels: [], comparedWithBase: true)
        harness.gitChangesEffect.value = { initial }
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.inspectorModel?.changes?.branch == "initial" }
        #expect(harness.sut.inspectorModel?.changes?.branch == "initial")
        
        // when — a manual reload (same path the 10 s poll and the "Reload" button use) publishes a
        // new result, with no full `recompute()` in between.
        let updated = GitChanges(files: [], diffs: [], commitsSinceBase: nil, branch: "updated", labels: [], comparedWithBase: true)
        harness.gitChangesEffect.value = { updated }
        await harness.sut.loadChanges()
        
        // then — both `changesModel` (already covered elsewhere) and the Inspector reflect it.
        #expect(harness.sut.changes?.branch == "updated")
        #expect(harness.sut.inspectorModel?.changes?.branch == "updated")
    }
    
    // MARK: - Item s: Terminal pane end/close
    
    @Test func givenATerminalSession_whenEndingIt_thenTerminatingBecomesTrueSynchronously() async throws {
        // given
        let harness = makeSUT()
        let running = task(status: "running")
        let session = TerminalSession(
            kind: .takeover(taskID: "abc12345"), title: "claude", backend: "claude",
            command: try TakeoverWrapper.command(argv: ["/bin/cat"], cwd: "/tmp", environment: [:])
        )
        session.start()
        harness.detailBox.value = running
        harness.sessionBox.value = session
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.terminalSession != nil }
        #expect(!session.terminating)
        
        // when
        harness.sut.didTapEndSession()
        
        // then — flips synchronously; the actual reap happens off the main queue
        #expect(session.terminating)
        
        // cleanup: let the real child actually finish tearing down before the test ends
        await waitUntil { session.ended }
    }
    
    @Test func givenATerminalSession_whenClosingIt_thenRemoveSessionIsCalledWithIt() async throws {
        // given
        let harness = makeSUT()
        let running = task(status: "running")
        let session = TerminalSession(
            kind: .interactive, title: "claude", backend: "claude",
            command: try TakeoverWrapper.command(argv: ["/bin/cat"], cwd: "/tmp", environment: [:])
        )
        harness.detailBox.value = running
        harness.sessionBox.value = session
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.terminalSession != nil }
        
        // when
        harness.sut.didTapCloseSession()
        
        // then
        verify(harness.useCase).removeSession(.any).called(1)
    }
    
    // MARK: - Item t: resume routes even after the VM is released
    
    @Test func givenResumeSucceeds_whenTheVMIsReleasedBeforeItCompletes_thenRoutingStillFiresOnTheNewTask() async {
        // given
        weak var weakSUT: TaskDetailVM?
        var capturedRouting: MockTaskDetailRouting!
        do {
            let harness = makeSUT()
            weakSUT = harness.sut
            capturedRouting = harness.routing
            let done = task(status: "completed")
            harness.detailBox.value = done
            harness.sut.didAppear()
            harness.tasksSubject.send([done])
            await waitUntil { harness.sut.task != nil }
            
            // when — submit while the VM is still alive; `submitMessage`'s resume branch captures
            // `useCase`/`routing` strongly, never `self`, so releasing the VM right after must not
            // stop the in-flight resume from routing.
            #expect(harness.sut.submitMessage("follow up"))
        }
        
        // then — nothing above kept `sut` alive
        #expect(weakSUT == nil)
        await verify(capturedRouting).selectTask(.value("newTaskID")).calledEventually(1, before: .seconds(1))
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
