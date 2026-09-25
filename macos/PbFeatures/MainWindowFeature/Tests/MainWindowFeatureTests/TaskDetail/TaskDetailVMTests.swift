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
@Suite struct TaskDetailVMTests {
    
    /// Records the order of lease acquisition and event-publisher requests (a fresh suite instance per test).
    let callOrder = Box<[String]>([])
    
    final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
    
    func task(
        id: String = "abc12345", backend: String = "claude", status: String = "running",
        repoPath: String = "/repo", spawnedBy: String? = nil, sessionID: String? = "sess-1234567890",
        liveInput: Bool = false, takenOver: Bool = false, freedom: String? = "read_only",
        summary: String? = nil, enforcement: [String: JSONValue]? = nil
    ) -> TaskInfo {
        var object: [String: JSONValue] = [
            "task_id": .string(id), "backend": .string(backend), "status": .string(status),
            "repo_path": .string(repoPath), "live_input": .bool(liveInput), "taken_over": .bool(takenOver)
        ]
        if let spawnedBy { object["spawned_by"] = .string(spawnedBy) }
        if let sessionID { object["session_id"] = .string(sessionID) }
        if let freedom { object["freedom"] = .string(freedom) }
        if let summary { object["summary"] = .string(summary) }
        if let enforcement { object["enforcement"] = .object(enforcement) }
        return TaskInfo(.object(object))!
    }
    
    struct SUT {
        let sut: TaskDetailVM
        let useCase: MockTaskDetailUseCase
        let routing: MockTaskDetailRouting
        let tasksSubject: PassthroughSubject<[TaskInfo], Never>
        let hasListedSubject: PassthroughSubject<Bool, Never>
        let snapshotsSubject: PassthroughSubject<[String: TaskInfo], Never>
        let busySubject: PassthroughSubject<Set<String>, Never>
        let outcomesSubject: PassthroughSubject<[String: String], Never>
        let sessionsSubject: PassthroughSubject<[TerminalSession], Never>
        let itemsSubject: PassthroughSubject<[TimelineItem], Never>
        let detailBox: Box<TaskInfo?>
        let snapshotBox: Box<TaskInfo?>
        let sessionBox: Box<TerminalSession?>
        let eventsBox: Box<[TaskEvent]>
        let scheduleBox: Box<(interval: TimeInterval, work: () -> Void)?>
        let cancelledSchedules: Box<Int>
        let ancestorsBox: Box<[TaskInfo]>
        let refreshSnapshotEffect: Box<(() -> Void)?>
        let gitChangesEffect: Box<(() -> GitChanges)?>
        let childrenBox: Box<[TaskInfo]>
    }
    
    /// The fixtures `makeSUT` builds before wiring up `useCase`'s stubs — split out purely to keep
    /// `makeSUT`/`configureStubs` each under the house function-length limit; no behavior change.
    struct Fixtures {
        let tasksSubject = PassthroughSubject<[TaskInfo], Never>()
        let hasListedSubject = PassthroughSubject<Bool, Never>()
        let titlesSubject = PassthroughSubject<[String: String], Never>()
        let snapshotsSubject = PassthroughSubject<[String: TaskInfo], Never>()
        let busySubject = PassthroughSubject<Set<String>, Never>()
        let outcomesSubject = PassthroughSubject<[String: String], Never>()
        let sessionsSubject = PassthroughSubject<[TerminalSession], Never>()
        let itemsSubject = PassthroughSubject<[TimelineItem], Never>()
        
        let detailBox = Box<TaskInfo?>(nil)
        let snapshotBox = Box<TaskInfo?>(nil)
        let sessionBox = Box<TerminalSession?>(nil)
        let eventsBox = Box<[TaskEvent]>([])
        let scheduleBox = Box<(interval: TimeInterval, work: () -> Void)?>(nil)
        let cancelledSchedules = Box<Int>(0)
        let ancestorsBox = Box<[TaskInfo]>([])
        let childrenBox = Box<[TaskInfo]>([])
        // Test-installable hooks consulted by the single `refreshSnapshot`/`gitChanges` stubs below
        // — re-stubbing the same member a second time is FIFO/unreliable (see `ParallelVMTests`'s
        // `Box` note), so a test that needs to observe/react to a call, or vary its result across
        // calls, installs a closure here instead of calling `given(...)` again.
        let refreshSnapshotEffect = Box<(() -> Void)?>(nil)
        let gitChangesEffect = Box<(() -> GitChanges)?>(nil)
    }
    
    func configureStubs(useCase: MockTaskDetailUseCase, routing: MockTaskDetailRouting, taskID: String, fixtures: Fixtures) {
        given(useCase).tasksPublisher().willReturn(fixtures.tasksSubject.eraseToAnyPublisher())
        given(useCase).hasListedPublisher().willReturn(fixtures.hasListedSubject.eraseToAnyPublisher())
        given(useCase).titlesPublisher().willReturn(fixtures.titlesSubject.eraseToAnyPublisher())
        given(useCase).snapshotsPublisher().willReturn(fixtures.snapshotsSubject.eraseToAnyPublisher())
        given(useCase).busyPublisher().willReturn(fixtures.busySubject.eraseToAnyPublisher())
        given(useCase).outcomesPublisher().willReturn(fixtures.outcomesSubject.eraseToAnyPublisher())
        given(useCase).sessionsPublisher().willReturn(fixtures.sessionsSubject.eraseToAnyPublisher())
        given(useCase).itemsPublisher(for: .value(taskID)).willProduce { [callOrder] _ in
            callOrder.value.append("itemsPublisher")
            return fixtures.itemsSubject.eraseToAnyPublisher()
        }
        
        given(useCase).detail(.value(taskID)).willProduce { _ in fixtures.detailBox.value }
        given(useCase).task(.any).willProduce { id in id == taskID ? fixtures.detailBox.value : nil }
        given(useCase).title(.any).willProduce { id in "Task \(id.prefix(8))" }
        given(useCase).ancestors(of: .any).willProduce { _ in fixtures.ancestorsBox.value }
        given(useCase).children(of: .value(taskID)).willProduce { _ in fixtures.childrenBox.value }
        given(useCase).siblings(of: .value(taskID)).willReturn([])
        
        given(useCase).snapshot(.value(taskID)).willProduce { _ in fixtures.snapshotBox.value }
        given(useCase).refreshSnapshot(.value(taskID)).willProduce { _ in fixtures.refreshSnapshotEffect.value?() }
        
        given(useCase).session(forTask: .value(taskID)).willProduce { _ in fixtures.sessionBox.value }
        given(useCase).removeSession(.any).willReturn()
        
        let lease = MockEventStreamLease()
        given(lease).taskID.willReturn(taskID)
        given(lease).release().willReturn()
        given(useCase).acquireEventLease(.value(taskID)).willProduce { [callOrder] _ in
            callOrder.value.append("acquireEventLease")
            return lease
        }
        given(useCase).items(for: .value(taskID)).willReturn([])
        given(useCase).events(for: .value(taskID)).willProduce { _ in fixtures.eventsBox.value }
        given(useCase).eventsPath(for: .value(taskID)).willReturn("/tmp/\(taskID).events.jsonl")
        given(useCase).activity(for: .value(taskID)).willReturn(ActivityCounts())
        given(useCase).current(for: .value(taskID)).willReturn(nil)
        given(useCase).prompt(for: .value(taskID)).willReturn(nil)
        
        // A single, never-re-stubbed producer reading a mutable box — re-stubbing `gitChanges`
        // itself a second time is FIFO/unreliable (the same gotcha as `refreshSnapshotEffect` above).
        given(useCase).gitChanges(repo: .any, baseCommit: .any, startDirty: .any).willProduce { [callOrder] _, _, _ in
            callOrder.value.append("gitChanges")
            return fixtures.gitChangesEffect.value?()
            ?? GitChanges(files: [], diffs: [], commitsSinceBase: nil, branch: nil, labels: [], comparedWithBase: true)
        }
        given(useCase).schedule(after: .any, execute: .any).willProduce { [callOrder] interval, work in
            callOrder.value.append("schedule")
            fixtures.scheduleBox.value = (interval, work)
            return AnyCancellable { fixtures.cancelledSchedules.value += 1 }
        }
        given(useCase).previewFile(repo: .any, path: .any).willReturn(.unreadable)
        given(useCase).cancel(.any).willReturn(true)
        given(useCase).send(.any, text: .any).willReturn(true)
        // Routing happens via `onResumed` (item 4), not the return value. Mockable producers are
        // synchronous, so the async callback runs in a Task; tests poll for its effect.
        given(useCase).resume(.any, text: .any, onResumed: .any).willProduce { _, _, onResumed in
            Task { await onResumed("newTaskID") }
            return "newTaskID"
        }
        given(useCase).beginTakeover(taskID: .any, destination: .any).willReturn()
        given(routing).selectTask(.any).willReturn()
    }
    
    @discardableResult
    func makeSUT(taskID: String = "abc12345") -> SUT {
        let useCase = MockTaskDetailUseCase()
        let routing = MockTaskDetailRouting()
        let fixtures = Fixtures()
        configureStubs(useCase: useCase, routing: routing, taskID: taskID, fixtures: fixtures)
        
        let sut = TaskDetailVM(taskID: taskID, useCase: useCase, routing: routing)
        return SUT(
            sut: sut, useCase: useCase, routing: routing, tasksSubject: fixtures.tasksSubject,
            hasListedSubject: fixtures.hasListedSubject, snapshotsSubject: fixtures.snapshotsSubject,
            busySubject: fixtures.busySubject, outcomesSubject: fixtures.outcomesSubject,
            sessionsSubject: fixtures.sessionsSubject, itemsSubject: fixtures.itemsSubject,
            detailBox: fixtures.detailBox, snapshotBox: fixtures.snapshotBox, sessionBox: fixtures.sessionBox,
            eventsBox: fixtures.eventsBox, scheduleBox: fixtures.scheduleBox,
            cancelledSchedules: fixtures.cancelledSchedules, ancestorsBox: fixtures.ancestorsBox,
            refreshSnapshotEffect: fixtures.refreshSnapshotEffect, gitChangesEffect: fixtures.gitChangesEffect,
            childrenBox: fixtures.childrenBox
        )
    }
    
    // MARK: - MS-DETAIL-1: loading vs. removed
    
    @Test func givenATaskNotYetListed_whenShown_thenLoadingIsDistinctFromRemoved() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let hasListedSubject = harness.hasListedSubject
        let detailBox = harness.detailBox
        sut.didAppear()
        
        // when — not yet listed at all
        detailBox.value = nil
        hasListedSubject.send(false)
        tasksSubject.send([])
        
        // then
        #expect(sut.task == nil)
        #expect(sut.hasListed == false)
        
        // when — the listing has completed and the task genuinely is not in it (removed by retention)
        hasListedSubject.send(true)
        await waitUntil { sut.hasListed }
        
        // then
        #expect(sut.task == nil)
        #expect(sut.hasListed == true)
    }
    
    // MARK: - MS-DETAIL-2: tabs
    
    @Test func givenNoSession_whenListingTabs_thenTerminalIsAbsent() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let detailBox = harness.detailBox
        let sessionBox = harness.sessionBox
        detailBox.value = task()
        sessionBox.value = nil
        sut.didAppear()
        
        // when
        tasksSubject.send([task()])
        await waitUntil { sut.task != nil }
        
        // then — the exact base list, not merely "doesn't contain terminal" (which an inert VM whose
        // `tabs` never got recomputed would also satisfy).
        #expect(sut.tabs == [.timeline, .changes, .prompt, .raw])
        #expect(!sut.tabs.contains(.terminal))
    }
    
    @Test func givenASessionAppears_whenObserved_thenTheTabAutoSelectsTerminal() async throws {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let sessionsSubject = harness.sessionsSubject
        let detailBox = harness.detailBox
        let sessionBox = harness.sessionBox
        detailBox.value = task()
        sut.didAppear()
        tasksSubject.send([task()])
        await waitUntil { sut.task != nil }
        #expect(sut.tab == .timeline)
        
        // when
        let session = TerminalSession(
            kind: .takeover(taskID: "abc12345"), title: "claude", backend: "claude",
            command: try TakeoverWrapper.command(argv: ["/bin/cat"], cwd: "/tmp", environment: [:])
        )
        sessionBox.value = session
        sessionsSubject.send([session])
        
        // then
        await waitUntil { sut.tab == .terminal }
        #expect(sut.tab == .terminal)
        #expect(sut.tabs.firstIndex(of: .terminal) == 2)
    }
    
    // Regression (item 5): `.onChange(of: session?.id)` in the original never fired for its INITIAL
    // value (`TaskDetailView.swift:85`) — only a LATER change to non-nil switched tabs. A task
    // revisited while it already has a session (e.g. reselected after viewing another task) must
    // therefore still open on Timeline, not jump straight to Terminal.
    @Test func givenATaskRevisitedWithAnExistingSession_whenFirstObserved_thenItStaysOnTimeline() async throws {
        // given — the session already exists on the very FIRST recompute this (fresh) VM instance
        // ever runs, exactly like SwiftUI building a brand-new `TaskDetailContent` for a task that
        // already has a live/ended session from before.
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let detailBox = harness.detailBox
        let sessionBox = harness.sessionBox
        detailBox.value = task()
        let session = TerminalSession(
            kind: .takeover(taskID: "abc12345"), title: "claude", backend: "claude",
            command: try TakeoverWrapper.command(argv: ["/bin/cat"], cwd: "/tmp", environment: [:])
        )
        sessionBox.value = session
        
        // when
        sut.didAppear()
        tasksSubject.send([task()])
        await waitUntil { sut.tabs.contains(.terminal) }
        
        // then — the tab exists (so this is not vacuously true from an unobserved session), but the
        // VM never force-switched to it.
        #expect(sut.tabs.contains(.terminal))
        #expect(sut.tab == .timeline)
    }
    
    @Test func givenAnEndedSessionStillPresent_whenListingTabs_thenTerminalStaysAtIndexTwo() async throws {
        // given — an ended (but still present) takeover session keeps the Terminal tab, per F4-37.
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let sessionsSubject = harness.sessionsSubject
        let detailBox = harness.detailBox
        let sessionBox = harness.sessionBox
        detailBox.value = task()
        let session = TerminalSession(
            kind: .takeover(taskID: "abc12345"), title: "claude", backend: "claude",
            command: try TakeoverWrapper.command(argv: ["/bin/cat"], cwd: "/tmp", environment: [:])
        )
        sessionBox.value = session
        sut.didAppear()
        tasksSubject.send([task()])
        sessionsSubject.send([session])
        await waitUntil { sut.tabs.contains(.terminal) }
        
        // when — the session ends (still returned by `session(forTask:)`, just `ended == true`)
        session.start()
        session.terminate()
        tasksSubject.send([task()])
        
        // then
        await waitUntil { sut.tabs.firstIndex(of: .terminal) == 2 }
        #expect(sut.tabs.firstIndex(of: .terminal) == 2)
    }
    
}
