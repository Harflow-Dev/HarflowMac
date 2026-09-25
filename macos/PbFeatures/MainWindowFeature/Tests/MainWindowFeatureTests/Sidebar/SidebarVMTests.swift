import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbCommon
import PbTerminal
import PbTestUtilities
import Testing

@MainActor
@Suite struct SidebarVMTests {
    
    private func task(
        id: String, backend: String = "claude", status: String = "running", startedAt: Date? = .now,
        group: String? = nil, spawnedBy: String? = nil, repoPath: String = "/tmp/repo", freedom: String? = nil,
        durationSeconds: Double? = nil
    ) -> TaskInfo {
        var object: [String: JSONValue] = [
            "task_id": .string(id), "backend": .string(backend), "status": .string(status), "repo_path": .string(repoPath)
        ]
        if let startedAt { object["started_at"] = .string(ISO8601DateFormatter().string(from: startedAt)) }
        if let group { object["group"] = .string(group) }
        if let spawnedBy { object["spawned_by"] = .string(spawnedBy) }
        if let freedom { object["freedom"] = .string(freedom) }
        if let durationSeconds { object["duration_seconds"] = .number(durationSeconds) }
        return TaskInfo(.object(object))!
    }
    
    /// Never `.start()`ed, so `.ended` stays `false` — a "live" session fixture with no real process.
    private func session(kind: TerminalSession.Kind = .interactive, title: String = "claude · repo", backend: String = "claude") throws -> TerminalSession {
        try TerminalSession(kind: kind, title: title, backend: backend, command: TakeoverWrapper.command(argv: ["/bin/cat"], cwd: "/tmp", environment: [:]))
    }
    
    /// A plain mutable box read by a `willProduce` closure registered exactly once — `Mockable`'s
    /// FIFO stub queue does not reliably swap a member's answer for the very next call when a
    /// second `given(...).willReturn(...)` is registered after the first has already matched (see
    /// the Phase 3/4a reports). Mutating a box sidesteps it.
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
    
    private struct SUT {
        let sut: SidebarVM
        let useCase: MockSidebarUseCase
        let routing: MockSidebarRouting
        let tasksSubject: PassthroughSubject<[TaskInfo], Never>
        let listErrorSubject: PassthroughSubject<ToolError?, Never>
        let hasListedSubject: PassthroughSubject<Bool, Never>
        let sessionsSubject: PassthroughSubject<[TerminalSession], Never>
        let selectionSubject: PassthroughSubject<MonitorDestination?, Never>
        let sessionsByTask: Box<[String: TerminalSession]>
        let interactiveSessionsBox: Box<[TerminalSession]>
        let titlesSubject: PassthroughSubject<[String: String], Never>
        let titlesBox: Box<[String: String]>
        let routingSelectionBox: Box<MonitorDestination?>
    }
    
    private func makeSUT(connectionLine: String = "connecting…") -> SUT {
        let useCase = MockSidebarUseCase()
        let routing = MockSidebarRouting()
        let tasksSubject = PassthroughSubject<[TaskInfo], Never>()
        let listErrorSubject = PassthroughSubject<ToolError?, Never>()
        let hasListedSubject = PassthroughSubject<Bool, Never>()
        let sessionsSubject = PassthroughSubject<[TerminalSession], Never>()
        let selectionSubject = PassthroughSubject<MonitorDestination?, Never>()
        let titlesSubject = PassthroughSubject<[String: String], Never>()
        let sessionsByTask = Box<[String: TerminalSession]>([:])
        let interactiveSessionsBox = Box<[TerminalSession]>([])
        let titlesBox = Box<[String: String]>([:])
        let routingSelectionBox = Box<MonitorDestination?>(nil)
        
        given(useCase).connectionLine.willReturn(connectionLine)
        given(useCase).tasksPublisher().willReturn(tasksSubject.eraseToAnyPublisher())
        given(useCase).listErrorPublisher().willReturn(listErrorSubject.eraseToAnyPublisher())
        given(useCase).hasListedPublisher().willReturn(hasListedSubject.eraseToAnyPublisher())
        given(useCase).sessionsPublisher().willReturn(sessionsSubject.eraseToAnyPublisher())
        given(useCase).titlesPublisher().willReturn(titlesSubject.eraseToAnyPublisher())
        given(useCase).title(.any).willProduce { titlesBox.value[$0] ?? "Task \($0.prefix(8))" }
        given(useCase).session(forTask: .any).willProduce { sessionsByTask.value[$0] }
        given(useCase).interactiveSessions.willProduce { interactiveSessionsBox.value }
        given(routing).selection.willProduce { routingSelectionBox.value }
        given(routing).selectionPublisher().willReturn(selectionSubject.eraseToAnyPublisher())
        given(routing).select(.any).willReturn()
        given(routing).openNewSession().willReturn()
        
        let sut = SidebarVM(useCase: useCase, routing: routing)
        return SUT(
            sut: sut, useCase: useCase, routing: routing, tasksSubject: tasksSubject, listErrorSubject: listErrorSubject,
            hasListedSubject: hasListedSubject, sessionsSubject: sessionsSubject, selectionSubject: selectionSubject,
            sessionsByTask: sessionsByTask, interactiveSessionsBox: interactiveSessionsBox, titlesSubject: titlesSubject,
            titlesBox: titlesBox, routingSelectionBox: routingSelectionBox
        )
    }
    
    // MARK: - Search / filter (MS-SIDE-1)
    
    @Test func givenAMixedCaseQuery_whenFiltering_thenTitleIdAndRepoAllMatch() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let titlesBox = harness.titlesBox
        titlesBox.value = ["t1": "Fix the Login Bug", "t2": "Something else", "t3": "Something else"]
        sut.didAppear()
        tasksSubject.send([
            task(id: "t1", status: "completed"),
            task(id: "t2", status: "completed", repoPath: "/tmp/LOGIN-service"),
            task(id: "t3", status: "completed", repoPath: "/tmp/unrelated")
        ])
        await waitUntil { sut.recentRows.count == 3 }
        
        // when — matches by title (case-insensitive)
        sut.didChangeSearchQuery("LoGiN")
        
        // then
        #expect(Set(sut.recentRows.map(\.id)) == ["t1", "t2"])
        
        // when — matches by id
        sut.didChangeSearchQuery("t3")
        
        // then
        #expect(sut.recentRows.map(\.id) == ["t3"])
    }
    
    @Test func givenABackendFilterAndAMatchingDescendant_whenFiltering_thenTheWholeTreeIsKept() async {
        // given — a codex sub-task under a claude root: filtering to "codex" must still show the
        // whole tree (the root included), matching the old `SidebarView`'s `keep(_:)` retention.
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        sut.didAppear()
        let root = task(id: "root1", backend: "claude", status: "completed")
        let child = task(id: "sub1", backend: "codex", status: "completed", spawnedBy: "root1")
        
        // when
        tasksSubject.send([root, child])
        await waitUntil { sut.recentRows.count == 2 }
        sut.didSelectBackendFilter("codex")
        
        // then
        #expect(sut.recentRows.map(\.id) == ["root1", "sub1"])
        #expect(sut.recentRows.map(\.indent) == [0, 1])
    }
    
    // MARK: - Empty state (F4-43)
    
    @Test func givenNoTasksAndNoError_whenListed_thenTheEmptyStateShows() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let listErrorSubject = harness.listErrorSubject
        let hasListedSubject = harness.hasListedSubject
        sut.didAppear()
        
        // when
        hasListedSubject.send(true)
        listErrorSubject.send(nil)
        tasksSubject.send([])
        
        // then
        await waitUntil { sut.isEmptyState }
        #expect(sut.isEmptyState)
    }
    
    @Test func givenAListError_whenListed_thenTheEmptyStateDoesNotShow() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let listErrorSubject = harness.listErrorSubject
        let hasListedSubject = harness.hasListedSubject
        sut.didAppear()
        let error = ToolError.notFound(tool: "polybridge-ctl", searched: [])
        
        // when
        hasListedSubject.send(true)
        listErrorSubject.send(error)
        tasksSubject.send([])
        
        // then
        await waitUntil { sut.listErrorMessage != nil }
        #expect(sut.isEmptyState == false)
        #expect(sut.listErrorMessage == error.message)
        #expect(sut.isConnected == false)
    }
    
    // MARK: - Row metadata (F4-43)
    
    @Test func givenALiveSessionForATask_whenRenderingItsRow_thenTheTerminalIconShows() async throws {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let sessionsByTask = harness.sessionsByTask
        sessionsByTask.value["t1"] = try session()
        sut.didAppear()
        
        // when
        tasksSubject.send([task(id: "t1", status: "completed")])
        
        // then
        await waitUntil { sut.recentRows.count == 1 }
        #expect(sut.recentRows.first?.hasLiveSession == true)
    }
    
    @Test func givenNoLiveSessionForATask_whenRenderingItsRow_thenTheTerminalIconDoesNotShow() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        sut.didAppear()
        
        // when
        tasksSubject.send([task(id: "t1", status: "completed")])
        
        // then
        await waitUntil { sut.recentRows.count == 1 }
        #expect(sut.recentRows.first?.hasLiveSession == false)
    }
    
    @Test func givenASubTask_whenBuildingItsRow_thenMetaTextHasIndentAndSubTaskCountAndFreedom() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        sut.didAppear()
        let root = task(id: "root1", status: "completed", repoPath: "/tmp/repo", freedom: "write_in_repo")
        let child = task(id: "sub1", status: "completed", spawnedBy: "root1", repoPath: "/tmp/repo")
        
        // when
        tasksSubject.send([root, child])
        
        // then
        await waitUntil { sut.recentRows.count == 2 }
        let rootRow = sut.recentRows.first { $0.id == "root1" }
        #expect(rootRow?.metaText == "/tmp/repo · 1 sub-task · write_in_repo")
        #expect(rootRow?.indent == 0)
        let childRow = sut.recentRows.first { $0.id == "sub1" }
        #expect(childRow?.indent == 1)
    }
    
    @Test func givenARunningTask_whenBuildingItsRow_thenIsRunningAndStartedAtAreSet() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        sut.didAppear()
        let start = Date.now.addingTimeInterval(-42)
        
        // when
        tasksSubject.send([task(id: "t1", status: "running", startedAt: start)])
        
        // then — `TaskInfo.startedAt` round-trips through an ISO8601 string with no fractional
        // seconds, so compare with a sub-second tolerance rather than exact equality.
        await waitUntil { !sut.runningRows.isEmpty }
        #expect(sut.runningRows.first?.isRunning == true)
        #expect(abs((sut.runningRows.first?.startedAt ?? .distantPast).timeIntervalSince(start)) < 1)
    }
    
    // MARK: - Interactive sessions (F4-43)
    
    @Test func givenInteractiveSessions_whenListed_thenTheyAppearAsRows() async throws {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let sessionsSubject = harness.sessionsSubject
        let interactiveSessionsBox = harness.interactiveSessionsBox
        let interactive = try session(title: "claude · ~/repo")
        interactiveSessionsBox.value = [interactive]
        sut.didAppear()
        
        // when
        sessionsSubject.send([interactive])
        
        // then
        await waitUntil { !sut.interactiveRows.isEmpty }
        #expect(sut.interactiveRows.first?.id == interactive.id)
        #expect(sut.interactiveRows.first?.title == "claude · ~/repo")
    }
    
    // MARK: - Selection (SidebarRouting doubles as the read side)
    
    @Test func givenARowTapped_whenSelected_thenRoutingSelectIsCalled() {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let routing = harness.routing
        
        // when
        sut.didSelect(.task("abc123"))
        
        // then
        verify(routing).select(.value(.task("abc123"))).called(1)
    }
    
    @Test func givenAnExternalSelectionChange_whenPublished_thenSelectionUpdates() async {
        // given — e.g. "Open parent" in the still-app-target `TaskDetailView`, routed through the
        // same `MainWindowCoordinator.selection` this VM reads via `SidebarRouting`.
        let harness = makeSUT()
        let sut = harness.sut
        let selectionSubject = harness.selectionSubject
        sut.didAppear()
        #expect(sut.selection == nil)
        
        // when
        selectionSubject.send(.task("xyz789"))
        
        // then
        await waitUntil { sut.selection == .task("xyz789") }
        #expect(sut.selection == .task("xyz789"))
    }
    
    @Test func givenNewSessionTapped_whenCalled_thenRoutingOpenNewSessionIsCalled() {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let routing = harness.routing
        
        // when
        sut.didTapNewSession()
        
        // then
        verify(routing).openNewSession().called(1)
    }
    
    // MARK: - Teardown (root AGENTS.md rule 7)
    
    @Test func givenDidDisappearThenDidAppearAgain_whenTasksPublish_thenItResubscribesAndUpdates() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        sut.didAppear()
        tasksSubject.send([task(id: "t1", status: "completed")])
        await waitUntil { sut.recentRows.count == 1 }
        
        // when — `didDisappear()` cancels the subscription. Combine guarantees a cancelled
        // subscription never delivers again, but this VM's own pipeline hops through
        // `.receive(on: DispatchQueue.main)`, so a plain synchronous check after `send` would pass
        // trivially even if teardown were broken (the hop just would not have fired yet). Poll for
        // the *wrong* outcome with a bounded timeout instead of a fixed sleep — Codex review
        // flagged the earlier version of this test for exactly that gap.
        sut.didDisappear()
        tasksSubject.send([task(id: "t1", status: "completed"), task(id: "t2", status: "completed")])
        await waitUntil(timeout: 0.3) { sut.recentRows.count == 2 }
        
        // then — no subscription while torn down
        #expect(sut.recentRows.count == 1)
        
        // when — re-subscribing picks up fresh state
        sut.didAppear()
        tasksSubject.send([task(id: "t1", status: "completed"), task(id: "t2", status: "completed")])
        
        // then
        await waitUntil { sut.recentRows.count == 2 }
        #expect(sut.recentRows.count == 2)
    }
    
    @Test func givenATitleArrivesAfterTheTaskList_whenNoOtherEventFires_thenTheRowStillRefreshes() async {
        // given — F4-11/MS-LIST-5: titles load off-main, separately from the listing. A row must
        // pick up a late-arriving title on its own, not only on the next unrelated recompute.
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let titlesSubject = harness.titlesSubject
        let titlesBox = harness.titlesBox
        sut.didAppear()
        tasksSubject.send([task(id: "t1", status: "completed")])
        await waitUntil { sut.recentRows.count == 1 }
        #expect(sut.recentRows.first?.title == "Task t1")
        
        // when — no further `tasksSubject` emission, only the title arriving.
        titlesBox.value["t1"] = "Fix the login bug"
        titlesSubject.send(["t1": "Fix the login bug"])
        
        // then
        await waitUntil { sut.recentRows.first?.title == "Fix the login bug" }
        #expect(sut.recentRows.first?.title == "Fix the login bug")
    }
    
    @Test func givenARunningTaskWithNoStartedAtButARecordedDuration_whenBuildingItsRow_thenDurationSecondsCarriesTheFallback() async {
        // given — mirrors `TaskInfo.elapsed(now:)`'s own fallback chain (F4-48/MS-TERM-1's sibling
        // in `PbUI.TaskRow`): a running task with a recorded duration but no start time.
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        sut.didAppear()
        
        // when
        tasksSubject.send([task(id: "t1", status: "running", startedAt: nil, durationSeconds: 90)])
        
        // then
        await waitUntil { !sut.runningRows.isEmpty }
        #expect(sut.runningRows.first?.startedAt == nil)
        #expect(sut.runningRows.first?.durationSeconds == 90)
    }
    
    // MARK: - Selection re-sync on reappear (Codex review finding)
    
    @Test func givenSelectionChangedWhileHidden_whenReappearing_thenItReSyncsBeforeAnyNewPublish() async {
        // given — the coordinator/VM survive a window close/reopen (`MainWindowCoordinator`'s
        // `sharedSidebarVM()` caches the instance), so a selection made elsewhere while this screen
        // was disappeared must be picked up on `didAppear()`, not only on the next external change.
        let harness = makeSUT()
        let sut = harness.sut
        let selectionSubject = harness.selectionSubject
        let routingSelectionBox = harness.routingSelectionBox
        sut.didAppear()
        selectionSubject.send(.task("abc123"))
        await waitUntil { sut.selection == .task("abc123") }
        #expect(sut.selection == .task("abc123"))
        sut.didDisappear()
        
        // when — selection changes while hidden; `routing.selection` reflects it immediately, but
        // this VM's subscription is torn down so it never observes the publisher event itself.
        routingSelectionBox.value = .task("xyz789")
        
        // then
        sut.didAppear()
        #expect(sut.selection == .task("xyz789"))
    }
    
    // MARK: - Deselection (Codex review finding)
    
    @Test func givenNilSelection_whenSelected_thenRoutingSelectIsCalledWithNil() {
        // given — `List(selection:)` writes `nil` on deselection; the old
        // `List(selection: $model.selection)` accepted that directly, so this binding must too.
        let harness = makeSUT()
        let sut = harness.sut
        let routing = harness.routing
        
        // when
        sut.didSelect(nil)
        
        // then
        verify(routing).select(.value(nil)).called(1)
    }
}
