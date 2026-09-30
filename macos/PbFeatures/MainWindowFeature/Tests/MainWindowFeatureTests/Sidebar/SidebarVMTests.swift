import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbTestUtilities
import Testing

@MainActor
@Suite struct SidebarVMTests {
    
    // Not `private`: `SidebarVMTests+Tree.swift` uses it too, and `private` is file-scoped in Swift.
    func task(
        id: String, backend: String = "claude", status: String = "running", startedAt: Date? = .now,
        group: String? = nil, spawnedBy: String? = nil, parentTaskID: String? = nil, repoPath: String = "/tmp/repo", freedom: String? = nil,
        durationSeconds: Double? = nil
    ) -> TaskInfo {
        var object: [String: JSONValue] = [
            "task_id": .string(id), "backend": .string(backend), "status": .string(status), "repo_path": .string(repoPath)
        ]
        if let startedAt { object["started_at"] = .string(ISO8601DateFormatter().string(from: startedAt)) }
        if let group { object["group"] = .string(group) }
        if let spawnedBy { object["spawned_by"] = .string(spawnedBy) }
        if let parentTaskID { object["parent_task_id"] = .string(parentTaskID) }
        if let freedom { object["freedom"] = .string(freedom) }
        if let durationSeconds { object["duration_seconds"] = .number(durationSeconds) }
        return TaskInfo(.object(object))!
    }
    
    /// A plain mutable box read by a `willProduce` closure registered exactly once — `Mockable`'s
    /// FIFO stub queue does not reliably swap a member's answer for the very next call when a
    /// second `given(...).willReturn(...)` is registered after the first has already matched (see
    /// the Phase 3/4a reports). Mutating a box sidesteps it.
    final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
    
    struct SUT {
        let sut: SidebarVM
        let useCase: MockSidebarUseCase
        let routing: MockSidebarRouting
        let tasksSubject: PassthroughSubject<[TaskInfo], Never>
        let listErrorSubject: PassthroughSubject<ToolError?, Never>
        let hasListedSubject: PassthroughSubject<Bool, Never>
        let selectionSubject: PassthroughSubject<MonitorDestination?, Never>
        let titlesSubject: PassthroughSubject<[String: String], Never>
        let titlesBox: Box<[String: String]>
        let routingSelectionBox: Box<MonitorDestination?>
        let installStateSubject: PassthroughSubject<InstallState, Never>
        let lastCheckMessageSubject: PassthroughSubject<String?, Never>
        let installAnywayBlockedMessageSubject: PassthroughSubject<String?, Never>
        let installStateBox: Box<InstallState>
        let installNeedBox: Box<InstallNeed?>
        let installDestinationBox: Box<String?>
        let revealSubject: PassthroughSubject<PendingReveal, Never>
        let pendingRevealBox: Box<PendingReveal?>
        let catalogSubject: PassthroughSubject<BackendCatalog, Never>
        let catalogBox: Box<BackendCatalog>
    }

    func makeSUT(connectionLine: String = "connecting…", installState: InstallState = .idle, catalog: BackendCatalog = .empty) -> SUT {
        let useCase = MockSidebarUseCase()
        let routing = MockSidebarRouting()
        let tasksSubject = PassthroughSubject<[TaskInfo], Never>()
        let listErrorSubject = PassthroughSubject<ToolError?, Never>()
        let hasListedSubject = PassthroughSubject<Bool, Never>()
        let selectionSubject = PassthroughSubject<MonitorDestination?, Never>()
        let titlesSubject = PassthroughSubject<[String: String], Never>()
        let titlesBox = Box<[String: String]>([:])
        let routingSelectionBox = Box<MonitorDestination?>(nil)
        let installStateSubject = PassthroughSubject<InstallState, Never>()
        let lastCheckMessageSubject = PassthroughSubject<String?, Never>()
        let installAnywayBlockedMessageSubject = PassthroughSubject<String?, Never>()
        let installStateBox = Box<InstallState>(installState)
        let installNeedBox = Box<InstallNeed?>(nil)
        let installDestinationBox = Box<String?>(nil)
        let revealSubject = PassthroughSubject<PendingReveal, Never>()
        let pendingRevealBox = Box<PendingReveal?>(nil)
        let catalogSubject = PassthroughSubject<BackendCatalog, Never>()
        let catalogBox = Box<BackendCatalog>(catalog)

        given(useCase).connectionLine.willReturn(connectionLine)
        given(useCase).tasksPublisher().willReturn(tasksSubject.eraseToAnyPublisher())
        given(useCase).listErrorPublisher().willReturn(listErrorSubject.eraseToAnyPublisher())
        given(useCase).hasListedPublisher().willReturn(hasListedSubject.eraseToAnyPublisher())
        given(useCase).titlesPublisher().willReturn(titlesSubject.eraseToAnyPublisher())
        given(useCase).title(.any).willProduce { titlesBox.value[$0] ?? "Task \($0.prefix(8))" }
        given(useCase).backendCatalog.willProduce { catalogBox.value }
        given(useCase).backendCatalogPublisher().willReturn(catalogSubject.eraseToAnyPublisher())
        given(routing).selection.willProduce { routingSelectionBox.value }
        given(routing).selectionPublisher().willReturn(selectionSubject.eraseToAnyPublisher())
        given(routing).select(.any).willReturn()
        given(routing).openNewSession().willReturn()
        given(routing).pendingReveal.willProduce { pendingRevealBox.value }
        given(routing).revealPublisher().willReturn(revealSubject.eraseToAnyPublisher())
        given(routing).consumeReveal(requestID: .any).willReturn()

        given(useCase).installState.willProduce { installStateBox.value }
        given(useCase).installStatePublisher().willReturn(installStateSubject.eraseToAnyPublisher())
        given(useCase).lastCheckMessage.willReturn(nil)
        given(useCase).lastCheckMessagePublisher().willReturn(lastCheckMessageSubject.eraseToAnyPublisher())
        given(useCase).installAnywayBlockedMessage.willReturn(nil)
        given(useCase).installAnywayBlockedMessagePublisher().willReturn(installAnywayBlockedMessageSubject.eraseToAnyPublisher())
        given(useCase).installNeed(for: .any).willProduce { _ in installNeedBox.value }
        given(useCase).installDestination().willProduce { installDestinationBox.value }
        given(useCase).install().willReturn()
        given(useCase).installUvThenPolybridge().willReturn()
        given(useCase).retry().willReturn()
        given(useCase).checkAgain().willReturn()
        given(useCase).installAnyway().willReturn(true)
        given(useCase).reset().willReturn()

        let sut = SidebarVM(useCase: useCase, routing: routing)
        return SUT(
            sut: sut, useCase: useCase, routing: routing, tasksSubject: tasksSubject, listErrorSubject: listErrorSubject,
            hasListedSubject: hasListedSubject, selectionSubject: selectionSubject, titlesSubject: titlesSubject,
            titlesBox: titlesBox, routingSelectionBox: routingSelectionBox, installStateSubject: installStateSubject,
            lastCheckMessageSubject: lastCheckMessageSubject, installAnywayBlockedMessageSubject: installAnywayBlockedMessageSubject,
            installStateBox: installStateBox, installNeedBox: installNeedBox, installDestinationBox: installDestinationBox,
            revealSubject: revealSubject, pendingRevealBox: pendingRevealBox, catalogSubject: catalogSubject, catalogBox: catalogBox
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
        await waitUntil { sut.emptyStateMessage != nil }
        #expect(sut.emptyStateMessage == "No tasks yet. Tasks started through polybridge appear here.")
    }
    
    @Test func givenAListErrorThatIsNotAnInstallNeed_whenListed_thenTheEmptyStateDoesNotShowAndTheMessageForwards() async {
        // given — a plain (non-install-need) error still takes the old red-text path.
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let listErrorSubject = harness.listErrorSubject
        let hasListedSubject = harness.hasListedSubject
        sut.didAppear()
        let error = ToolError.refused(code: "denied", message: "polybridge-ctl refused the request.")

        // when
        hasListedSubject.send(true)
        listErrorSubject.send(error)
        tasksSubject.send([])

        // then
        await waitUntil { sut.listErrorMessage != nil }
        #expect(sut.emptyStateMessage == nil)
        #expect(sut.listErrorMessage == error.message)
        #expect(sut.isConnected == false)
        #expect(sut.installBannerModel == nil)
    }

    // Moved from a `.message`-forwarding assertion (settled plan, section 7): a `notFound` error
    // for `polybridge-ctl`/`polybridge-setup` is an install need, so it now shows the banner instead
    // of the plain red `listErrorMessage`, and the banner outranks the empty state exactly as the
    // old error did.
    @Test func givenAListErrorThatIsAnInstallNeed_whenListed_thenTheBannerShowsInsteadOfTheRedText() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        let tasksSubject = harness.tasksSubject
        let listErrorSubject = harness.listErrorSubject
        let hasListedSubject = harness.hasListedSubject
        harness.installNeedBox.value = .missing
        sut.didAppear()
        let error = ToolError.notFound(tool: "polybridge-ctl", searched: [])

        // when
        hasListedSubject.send(true)
        listErrorSubject.send(error)
        tasksSubject.send([])

        // then
        await waitUntil { sut.installBannerModel != nil }
        #expect(sut.emptyStateMessage == nil)
        #expect(sut.isConnected == false)
        #expect(sut.listErrorMessage == nil)
        #expect(sut.installBannerModel?.title == "polybridge isn't installed")
        #expect(sut.installBannerModel?.detail == error.message)
        #expect(sut.installBannerModel?.primaryTitle == "Install polybridge")
        verify(useCase).installNeed(for: .value(error)).called(1)
    }

    // MARK: - Loading skeleton (Monitor piece 11, Plan review round 1 item 4)

    @Test func givenNoListingHasArrivedYet_whenAppeared_thenTheLoadingSkeletonShows() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut

        // when
        sut.didAppear()

        // then — before `hasListedPublisher()`'s first value, this is the shimmer's whole reason to
        // exist: an empty list with no error and no install banner is otherwise indistinguishable
        // from "no tasks yet".
        #expect(sut.showsLoadingSkeleton)
        #expect(sut.emptyStateMessage == nil, "the empty-state message never shows while the skeleton does")
    }

    @Test func givenTheFirstListingArrives_whenObserved_thenTheLoadingSkeletonClears() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        #expect(sut.showsLoadingSkeleton)

        // when
        harness.hasListedSubject.send(true)
        harness.listErrorSubject.send(nil)
        harness.tasksSubject.send([])

        // then
        await waitUntil { !sut.showsLoadingSkeleton }
        #expect(sut.emptyStateMessage != nil, "now that hasListed is true, the ordinary empty state takes over")
    }

    @Test func givenAListErrorArrivesBeforeAnyListing_whenObserved_thenTheLoadingSkeletonNeverShows() async {
        // given — the error/banner UI gates first (`computeEmptyStateMessage()`'s own precedence);
        // the skeleton must never draw over it.
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()

        // when
        harness.listErrorSubject.send(ToolError.notFound(tool: "polybridge-ctl", searched: []))

        // then
        await waitUntil { sut.listErrorMessage != nil }
        #expect(!sut.showsLoadingSkeleton)
    }

    @Test func givenAnInstallBannerArrivesBeforeAnyListing_whenObserved_thenTheLoadingSkeletonNeverShows() async {
        // given — Codex review round 1, finding 3: `showsLoadingSkeleton` was only ever recomputed
        // inside `recompute()`, so a banner arriving via `installStatePublisher()` (none of
        // `subscribeToInstallState()`'s three subscriptions call `recompute()` themselves) before the
        // first listing left the skeleton rendering alongside the banner instead of yielding to it.
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        #expect(sut.showsLoadingSkeleton)

        // when — the install banner appears, with no listing published at all yet.
        harness.installStateSubject.send(.needsGit)

        // then
        await waitUntil { sut.installBannerModel != nil }
        #expect(!sut.showsLoadingSkeleton)
    }

    // MARK: - Row metadata (F4-43)

    @Test func givenASubTask_whenBuildingItsRow_thenSubtitleHasRepoNameBackendAndSubTaskCountButNoFreedom() async {
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
        #expect(rootRow?.subtitle == "repo · Claude · 1 sub-task")
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

    @Test func givenTwoIdenticalListings_whenTheClockAdvancesPastAThreshold_thenAgeTextUpdates() async {
        // given — Codex review round 1, finding 2: the tasks stream must NOT `.removeDuplicates()`,
        // or a byte-identical republish (the ordinary case while nothing about the task itself has
        // changed) would never recompute `ageText`, freezing it at whatever it read the last time
        // the array's own CONTENT changed.
        let harness = makeSUT()
        let sut = harness.sut
        let startedAt = Date().addingTimeInterval(-59.8)
        let completed = task(id: "t1", status: "completed", startedAt: startedAt)
        sut.didAppear()
        harness.tasksSubject.send([completed])
        await waitUntil { sut.recentRows.first?.ageText == "now" }

        // when — wait past the 60s boundary, then re-publish the SAME array (identical content).
        await waitUntil(timeout: 2) { Date().timeIntervalSince(startedAt) >= 60.1 }
        harness.tasksSubject.send([completed])

        // then
        await waitUntil { sut.recentRows.first?.ageText == "1m" }
        #expect(sut.recentRows.first?.ageText == "1m")
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

    // MARK: - Perf (Monitor piece 11)

    @Test func givenA2000TaskListingWithABackendFilterActive_whenRecomputed_thenItStaysFarBelowTheQuadraticCost() async {
        // given — the exact shape measured at 0.36s/recompute on the real 532-task listing with a
        // backend tab selected (113 matches): `forcedExpandedIDs` used to rebuild the whole
        // conversation tree once per MATCHING task. `ConversationIndexTests` already proves the
        // underlying `ConversationIndex` fix in isolation; this proves it through the real VM path
        // (`recompute()` building one index per publication and reusing it — Plan review round 1,
        // item 1), at roughly 4x the real listing's size for headroom.
        let harness = makeSUT()
        let sut = harness.sut
        var tasks: [TaskInfo] = []
        for index in 0 ..< 2000 {
            tasks.append(task(
                id: "t\(index)", backend: index % 2 == 0 ? "claude" : "codex", status: index % 7 == 0 ? "running" : "completed",
                startedAt: .now.addingTimeInterval(-Double(index)),
                spawnedBy: index % 5 == 0 && index > 0 ? "t\(index - 1)" : nil,
                parentTaskID: index % 3 == 0 && index > 0 ? "t\(index - 1)" : nil
            ))
        }
        sut.didAppear()

        // when
        let start = Date()
        harness.tasksSubject.send(tasks)
        sut.didSelectBackendFilter("claude")
        await waitUntil { !sut.runningRows.isEmpty || !sut.recentRows.isEmpty }
        let elapsed = Date().timeIntervalSince(start)

        // then
        // 3 s, not 1 s: this is wall-clock time through the real VM path — publisher hops and 50 ms
        // polling included — on a shared CI runner (1.06 s was seen there). The quadratic path this
        // guards against takes several seconds at this size; `ConversationIndexTests` holds the
        // tight, contention-free bound.
        #expect(
            elapsed < 3.0,
            "recompute() at 4x the real listing's size should stay well under the quadratic cost (\(elapsed)s)"
        )
    }
}
