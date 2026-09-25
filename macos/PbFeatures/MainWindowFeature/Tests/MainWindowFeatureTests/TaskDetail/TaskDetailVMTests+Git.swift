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
    
    // MARK: - MS-DETAIL-3: git polling
    
    @Test func givenARunningTask_whenPolling_thenGitIsAskedEvery10Seconds() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        let tasksSubject = harness.tasksSubject
        let detailBox = harness.detailBox
        let snapshotBox = harness.snapshotBox
        let scheduleBox = harness.scheduleBox
        let running = task(status: "running")
        detailBox.value = running
        snapshotBox.value = running
        sut.didAppear()
        
        // when
        tasksSubject.send([running])
        await waitUntil { scheduleBox.value != nil }
        
        // then
        #expect(scheduleBox.value?.interval == 10)
        await verify(useCase).gitChanges(repo: .value("/repo"), baseCommit: .any, startDirty: .any).calledEventually(1, before: .seconds(1))
        
        // when — invoking the scheduled work polls again
        scheduleBox.value?.work()
        
        // then
        await verify(useCase).gitChanges(repo: .value("/repo"), baseCommit: .any, startDirty: .any).calledEventually(2, before: .seconds(1))
    }
    
    // Regression: the original (`TaskDetailView.swift:74-81`) ran load, THEN waited 10 s, THEN
    // loaded again — sequentially. A `scheduleRepeating(every: 10)` timer instead re-fires every
    // 10 s regardless of whether the previous load finished, so a load slower than 10 s is
    // superseded by the generation guard every time and never publishes. The one-shot
    // `schedule(after:)` seam is only armed AFTER `gitChanges` has been awaited and returned, never
    // before — this is the property that keeps the poll sequential instead of overlapping.
    @Test func givenALoadWaitingOnItsSnapshot_whenTheScreenDisappears_thenGitIsNeverAsked() async {
        // given — no cached snapshot, so the load first waits on `refreshSnapshot`
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        let tasksSubject = harness.tasksSubject
        let detailBox = harness.detailBox
        let snapshotBox = harness.snapshotBox
        let refreshSnapshotEffect = harness.refreshSnapshotEffect
        let running = task(status: "running")
        detailBox.value = running
        snapshotBox.value = nil
        let refreshed = Box(false)
        refreshSnapshotEffect.value = {
            // when — the screen goes away while the snapshot request is in flight (the original's
            // `.task` was cancelled here and stopped at its post-snapshot check)
            sut.didDisappear()
            snapshotBox.value = running
            refreshed.value = true
        }
        sut.didAppear()
        tasksSubject.send([running])
        await waitUntil { refreshed.value }
        #expect(refreshed.value)
        await waitUntil(timeout: 0.3) { sut.changes != nil }
        
        // then
        verify(useCase).gitChanges(repo: .any, baseCommit: .any, startDirty: .any).called(0)
        #expect(sut.changes == nil)
    }
    
    @Test func givenARunningTask_whenPolling_thenTheNextPollIsScheduledOnlyAfterTheLoadCompletes() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let detailBox = harness.detailBox
        let snapshotBox = harness.snapshotBox
        let scheduleBox = harness.scheduleBox
        let running = task(status: "running")
        detailBox.value = running
        snapshotBox.value = running
        sut.didAppear()
        
        // when
        tasksSubject.send([running])
        await waitUntil { scheduleBox.value != nil }
        
        // then — the recorded order shows the git load being awaited to completion before the next
        // cycle is ever scheduled, never the reverse.
        let gitIndex = callOrder.value.firstIndex(of: "gitChanges")
        let scheduleIndex = callOrder.value.firstIndex(of: "schedule")
        #expect(gitIndex != nil)
        #expect(scheduleIndex != nil)
        if let gitIndex, let scheduleIndex {
            #expect(gitIndex < scheduleIndex)
        }
    }
    
    @Test func givenAStatusChange_whenObserved_thenTheGitPollRestarts() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
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
        let cancelledBefore = cancelledSchedules.value
        
        // when — status changes to terminal: the running poll is cancelled and not restarted
        let completed = task(status: "completed")
        detailBox.value = completed
        scheduleBox.value = nil
        tasksSubject.send([completed])
        
        // then
        await waitUntil { cancelledSchedules.value > cancelledBefore }
        #expect(cancelledSchedules.value > cancelledBefore)
        #expect(scheduleBox.value == nil)
    }
    
    @Test func givenTheSameStatusPublishedTwice_whenObserved_thenGitRunsOnceAndThePollIsNotRestarted() async {
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
        #expect(scheduleBox.value != nil)
        await verify(useCase).gitChanges(repo: .value("/repo"), baseCommit: .any, startDirty: .any).calledEventually(1, before: .seconds(1))
        
        // when — another listing publish with an unchanged status (a refresh, a title load, …)
        tasksSubject.send([running])
        tasksSubject.send([running])
        await waitUntil(timeout: 0.3) { cancelledSchedules.value > 0 }
        
        // then — only a status change restarts git (the original `.task(id: task.status)`)
        #expect(cancelledSchedules.value == 0)
        verify(useCase).gitChanges(repo: .any, baseCommit: .any, startDirty: .any).called(1)
        verify(useCase).schedule(after: .any, execute: .any).called(1)
    }
    
    @Test func givenAFirstAppearance_whenSubscribing_thenTheLeaseIsAcquiredBeforeTheEventPublisherIsRequested() {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        
        // when
        sut.didAppear()
        
        // then — the repository only has a live stream for a leased task
        #expect(callOrder.value.first == "acquireEventLease")
        #expect(callOrder.value.contains("itemsPublisher"))
    }
    
    @Test func givenAnOlderSlowerRequest_whenANewerOneAlreadyPublished_thenTheOlderNeverOverwritesIt() async {
        // given — the generation guard: `loadChanges()` must never let an older, slower request
        // overwrite a result a newer one already published. Mockable's generated `willProduce` for
        // an `async` member only takes a *synchronous* producer (no suspending overload — see
        // `HarnessesVMTests`'s note on the same limitation), so real concurrent overlap cannot be
        // simulated directly, and re-stubbing the same member a second time is FIFO/unreliable (the
        // house `Box` gotcha — see `ParallelVMTests`). Instead, `gitChangesEffect` — a hook the
        // single, never-re-stubbed `gitChanges` producer always consults — synchronously mutates
        // `sut.changesGeneration`/`sut.changes` as a stand-in for "a newer request slipped in and
        // published its own result while this one was still computing its answer", which is exactly
        // the race the guard exists to close.
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let detailBox = harness.detailBox
        let snapshotBox = harness.snapshotBox
        let gitChangesEffect = harness.gitChangesEffect
        let running = task(status: "running")
        detailBox.value = running
        snapshotBox.value = running
        let initial = GitChanges(files: [], diffs: [], commitsSinceBase: nil, branch: "initial", labels: [], comparedWithBase: true)
        gitChangesEffect.value = { initial }
        // `sut.task` must be set (via the normal recompute path) before calling `loadChanges()`
        // directly, and this first recompute's own automatic git load must settle first so it does
        // not race the manual call below.
        sut.didAppear()
        tasksSubject.send([running])
        await waitUntil { sut.changes?.branch == "initial" }
        
        // when — a second, manual `loadChanges()` call whose `gitChangesEffect` simulates a newer
        // request completing (bumping the generation and publishing its own result) while this
        // (older) call is still "in flight" computing its own answer.
        let fast = GitChanges(files: [], diffs: [], commitsSinceBase: nil, branch: "fast", labels: [], comparedWithBase: true)
        let slow = GitChanges(files: [], diffs: [], commitsSinceBase: nil, branch: "slow", labels: [], comparedWithBase: true)
        gitChangesEffect.value = {
            sut.changesGeneration += 1
            sut.changes = fast
            return slow
        }
        await sut.loadChanges()
        
        // then — the guard refuses to overwrite the newer, already-published result
        #expect(sut.changes?.branch == "fast")
    }
    
}
