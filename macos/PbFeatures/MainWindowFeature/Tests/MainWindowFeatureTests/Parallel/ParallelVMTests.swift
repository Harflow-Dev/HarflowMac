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
@Suite struct ParallelVMTests {
    
    private func task(
        id: String, backend: String = "claude", status: String = "running", startedAt: Date? = .now,
        group: String? = "g1", freedom: String? = nil, sessionID: String? = "sess-1234567890",
        summary: String? = nil, enforcement: [String: JSONValue]? = nil
    ) -> TaskInfo {
        var object: [String: JSONValue] = [
            "task_id": .string(id), "backend": .string(backend), "status": .string(status)
        ]
        if let startedAt { object["started_at"] = .string(ISO8601DateFormatter().string(from: startedAt)) }
        if let group { object["group"] = .string(group) }
        if let freedom { object["freedom"] = .string(freedom) }
        if let sessionID { object["session_id"] = .string(sessionID) }
        if let summary { object["summary"] = .string(summary) }
        if let enforcement { object["enforcement"] = .object(enforcement) }
        return TaskInfo(.object(object))!
    }
    
    /// A plain mutable box read by a `willProduce` closure registered exactly once — `Mockable`'s
    /// FIFO stub queue does not reliably swap a member's answer for the very next call (see the
    /// Phase 3/4a/4b reports). Mutating a box sidesteps it.
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
    
    private struct SUT {
        let sut: ParallelVM
        let useCase: MockParallelUseCase
        let routing: MockParallelRouting
        let tasksSubject: PassthroughSubject<[TaskInfo], Never>
        let snapshotsSubject: PassthroughSubject<[String: TaskInfo], Never>
        let busySubject: PassthroughSubject<Set<String>, Never>
        let outcomesSubject: PassthroughSubject<[String: String], Never>
        let titlesSubject: PassthroughSubject<[String: String], Never>
        let tasksBox: Box<[String: TaskInfo]>
        let titlesBox: Box<[String: String]>
        let itemsBox: Box<[String: [TimelineItem]]>
        let availabilityBox: Box<[String: EventAvailability]>
        let leasesBox: Box<[String: MockEventStreamLease]>
        let releasedBox: Box<Set<String>>
        let runningInSubtreesBox: Box<[String]?>
    }

    private func makeSUT(groupName: String = "g1") -> SUT {
        let useCase = MockParallelUseCase()
        let routing = MockParallelRouting()
        let tasksSubject = PassthroughSubject<[TaskInfo], Never>()
        let snapshotsSubject = PassthroughSubject<[String: TaskInfo], Never>()
        let busySubject = PassthroughSubject<Set<String>, Never>()
        let outcomesSubject = PassthroughSubject<[String: String], Never>()
        let titlesSubject = PassthroughSubject<[String: String], Never>()
        let tasksBox = Box<[String: TaskInfo]>([:])
        let titlesBox = Box<[String: String]>([:])
        let itemsBox = Box<[String: [TimelineItem]]>([:])
        let availabilityBox = Box<[String: EventAvailability]>([:])
        let leasesBox = Box<[String: MockEventStreamLease]>([:])
        let releasedBox = Box<Set<String>>([])
        let runningInSubtreesBox = Box<[String]?>(nil)

        given(useCase).tasksPublisher().willReturn(tasksSubject.eraseToAnyPublisher())
        given(useCase).snapshotsPublisher().willReturn(snapshotsSubject.eraseToAnyPublisher())
        given(useCase).busyPublisher().willReturn(busySubject.eraseToAnyPublisher())
        given(useCase).outcomesPublisher().willReturn(outcomesSubject.eraseToAnyPublisher())
        given(useCase).titlesPublisher().willReturn(titlesSubject.eraseToAnyPublisher())
        given(useCase).task(.any).willProduce { tasksBox.value[$0] }
        given(useCase).title(.any).willProduce { titlesBox.value[$0] ?? "Task \($0.prefix(8))" }
        given(useCase).items(for: .any).willProduce { itemsBox.value[$0] ?? [] }
        given(useCase).itemsPublisher(for: .any).willProduce { id in Just(itemsBox.value[id] ?? []).eraseToAnyPublisher() }
        given(useCase).prompt(for: .any).willReturn(nil)
        given(useCase).eventsAvailability(for: .any).willProduce { availabilityBox.value[$0] ?? .loading }
        given(useCase).eventsAvailabilityPublisher(for: .any).willProduce { id in
            Just(availabilityBox.value[id] ?? .loading).eraseToAnyPublisher()
        }
        given(useCase).acquireEventLease(.any).willProduce { id in
            let lease = MockEventStreamLease()
            given(lease).taskID.willReturn(id)
            given(lease).release().willProduce { releasedBox.value.insert(id) }
            leasesBox.value[id] = lease
            return lease
        }
        given(useCase).runningInSubtrees(of: .any).willProduce { ids in runningInSubtreesBox.value ?? ids }
        given(useCase).cancelAll(.any).willReturn()
        given(useCase).beginTakeover(taskID: .any).willReturn()
        given(routing).selectTask(.any).willReturn()

        let sut = ParallelVM(groupName: groupName, useCase: useCase, routing: routing)
        return SUT(
            sut: sut, useCase: useCase, routing: routing, tasksSubject: tasksSubject, snapshotsSubject: snapshotsSubject,
            busySubject: busySubject, outcomesSubject: outcomesSubject, titlesSubject: titlesSubject,
            tasksBox: tasksBox, titlesBox: titlesBox, itemsBox: itemsBox, availabilityBox: availabilityBox,
            leasesBox: leasesBox, releasedBox: releasedBox, runningInSubtreesBox: runningInSubtreesBox
        )
    }
    
    // MARK: - Fresh listing entry (F4-40)
    
    @Test func givenTheColumnUsesTheFreshListingEntry_whenTheTaskUpdates_thenTheColumnReflectsIt() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let busySubject = harness.busySubject
        let tasksBox = harness.tasksBox
        let titlesBox = harness.titlesBox
        let task1 = task(id: "t1", status: "running")
        tasksBox.value["t1"] = task1
        titlesBox.value["t1"] = "Fix the bug"
        sut.didAppear()
        
        // when
        tasksSubject.send([task1])
        await waitUntil { sut.columns.count == 1 }
        
        // then
        #expect(sut.columns.first?.task.status == .running)
        #expect(sut.columns.first?.title == "Fix the bug")
        
        // when — the task's own status changes; a different publisher (busy) fires the recompute,
        // not a fresh `tasksPublisher` emission, but the column must still show the current value
        // because it always re-reads `useCase.task(_:)` rather than a cached copy.
        tasksBox.value["t1"] = task(id: "t1", status: "completed")
        busySubject.send([])
        
        // then
        await waitUntil { sut.columns.first?.task.status == .completed }
        #expect(sut.columns.first?.task.status == .completed)
    }
    
    @Test func givenATitleArrivesAfterTheTaskList_whenNoOtherEventFires_thenTheColumnStillRefreshes() async {
        // given — F4-11/MS-LIST-5: titles load off-main, separately from the listing (Codex review
        // finding: a column must pick up a late-arriving title on its own, not only on the next
        // unrelated recompute).
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let titlesSubject = harness.titlesSubject
        let tasksBox = harness.tasksBox
        let titlesBox = harness.titlesBox
        let task1 = task(id: "t1")
        tasksBox.value["t1"] = task1
        sut.didAppear()
        tasksSubject.send([task1])
        await waitUntil { sut.columns.count == 1 }
        #expect(sut.columns.first?.title == "Task t1")
        
        // when — no further `tasksSubject` emission, only the title arriving.
        titlesBox.value["t1"] = "Fix the login bug"
        titlesSubject.send(["t1": "Fix the login bug"])
        
        // then
        await waitUntil { sut.columns.first?.title == "Fix the login bug" }
        #expect(sut.columns.first?.title == "Fix the login bug")
    }
    
    @Test func givenAnEmptyGroup_whenTasksPublish_thenIsEmptyIsSetAndNoColumnsAppear() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        sut.didAppear()
        
        // when
        tasksSubject.send([])
        
        // then
        await waitUntil { sut.isEmpty }
        #expect(sut.isEmpty)
        #expect(sut.columns.isEmpty)
    }
    
    // MARK: - Summary: snapshot only, no `task.summary` fallback (F4-40)
    
    @Test func givenNoSnapshotSummary_whenRenderingTheColumn_thenNoSummaryShowsEvenIfTheListingHasOne() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let snapshotsSubject = harness.snapshotsSubject
        let tasksBox = harness.tasksBox
        let task1 = task(id: "t1", status: "completed", summary: "from the listing")
        tasksBox.value["t1"] = task1
        sut.didAppear()
        tasksSubject.send([task1])
        await waitUntil { sut.columns.count == 1 }
        
        // then — the listing's own `summary` field is never shown
        #expect(sut.columns.first?.summary == nil)
        
        // when — a snapshot with its own summary arrives
        snapshotsSubject.send(["t1": task(id: "t1", status: "completed", summary: "from the snapshot")])
        
        // then
        await waitUntil { sut.columns.first?.summary == "from the snapshot" }
        #expect(sut.columns.first?.summary == "from the snapshot")
    }
    
    // MARK: - Embedded takeover (decision 5)
    
    @Test func givenAnEmbeddedTakeover_whenConfirmed_thenSelectionMovesToTheTaskScreen() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        let routing = harness.routing
        let tasksSubject = harness.tasksSubject
        let tasksBox = harness.tasksBox
        let task1 = task(id: "t1", status: "running")
        tasksBox.value["t1"] = task1
        sut.didAppear()
        tasksSubject.send([task1])
        await waitUntil { sut.columns.count == 1 }
        var capturedEvent: ViewEvent?
        let cancellable = sut.objectDidPublishViewEvent.publisher.sink { capturedEvent = $0 }
        
        // when
        sut.columns.first?.onTapTakeover()
        await waitUntil { capturedEvent?.dialog != nil }
        guard case .dialog(let dialog) = capturedEvent else {
            Issue.record("expected a .dialog event")
            cancellable.cancel()
            return
        }
        #expect(dialog.title == "Take over this task?")
        #expect(dialog.actions.count == 1)
        #expect(dialog.actions.first?.title == "Stop it and take over")
        dialog.actions.first?.action()
        
        // then
        verify(useCase).beginTakeover(taskID: .value("t1")).called(1)
        verify(routing).selectTask(.value("t1")).called(1)
        cancellable.cancel()
    }
    
    @Test func givenATerminalTaskTakeover_whenTapped_thenTheDialogOffersToContinueInATerminal() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let tasksBox = harness.tasksBox
        let task1 = task(id: "t1", status: "completed", freedom: "read_only")
        tasksBox.value["t1"] = task1
        sut.didAppear()
        tasksSubject.send([task1])
        await waitUntil { sut.columns.count == 1 }
        var capturedEvent: ViewEvent?
        let cancellable = sut.objectDidPublishViewEvent.publisher.sink { capturedEvent = $0 }
        
        // when
        sut.columns.first?.onTapTakeover()
        
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
            == "The headless run is stopped first if it is still going, then the same conversation opens in Terminal.app. It runs "
            + "under your own default permissions, not read_only."
        )
        cancellable.cancel()
    }
    
    // MARK: - Cancel all (MS-SIDE-4)
    
    @Test func givenARunningSubTask_whenCountingRunningTasksAndBuildingCancelAll_thenItIsIncludedInBoth() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        let tasksSubject = harness.tasksSubject
        let tasksBox = harness.tasksBox
        let runningInSubtreesBox = harness.runningInSubtreesBox
        let task1 = task(id: "t1", status: "running")
        tasksBox.value["t1"] = task1
        runningInSubtreesBox.value = ["t1", "sub-of-t1"]
        sut.didAppear()
        tasksSubject.send([task1])
        await waitUntil { sut.canCancelAll }
        var capturedEvent: ViewEvent?
        let cancellable = sut.objectDidPublishViewEvent.publisher.sink { capturedEvent = $0 }
        
        // when
        sut.didTapCancelAll()
        await waitUntil { capturedEvent?.dialog != nil }
        guard case .dialog(let dialog) = capturedEvent else {
            Issue.record("expected a .dialog event")
            cancellable.cancel()
            return
        }
        #expect(dialog.title == "Cancel every running task in this group?")
        #expect(dialog.actions.count == 1)
        #expect(dialog.actions.first?.role == .destructive)
        dialog.actions.first?.action()
        
        // then — every running task in the members' subtrees is cancelled, sub-tasks included
        await verify(useCase).cancelAll(.value(["t1", "sub-of-t1"])).calledEventually(1, before: .seconds(5))
        cancellable.cancel()
    }
    
    @Test func givenNoRunningMember_whenTapped_thenCancelAllDoesNothing() async {
        // given — `canCancelAll` starts `false` and `didTapCancelAll` guards on it, so a tap before
        // any running member exists must not publish a dialog. Round-2 Codex review: a negative
        // assertion alone still passes against a no-op `didTapCancelAll()`, so first prove the
        // *positive* case (a running member really does produce a dialog), then transition to no
        // running members and prove a second tap produces none. `publishViewEvent` delivers through a
        // `Task { @MainActor in ... }` hop, so the negative half polls for the *wrong* outcome with a
        // bounded timeout (the established house pattern) rather than checking synchronously.
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let tasksBox = harness.tasksBox
        let running = task(id: "t1", status: "running")
        tasksBox.value["t1"] = running
        sut.didAppear()
        tasksSubject.send([running])
        await waitUntil { sut.canCancelAll }
        var capturedEvent: ViewEvent?
        let cancellable = sut.objectDidPublishViewEvent.publisher.sink { capturedEvent = $0 }
        
        // when — a running member: the dialog really does fire.
        sut.didTapCancelAll()
        await waitUntil { capturedEvent?.dialog != nil }
        #expect(capturedEvent?.dialog != nil)
        capturedEvent = nil
        
        // when — the member settles, so no running member remains.
        tasksSubject.send([task(id: "t1", status: "completed")])
        await waitUntil { !sut.canCancelAll }
        sut.didTapCancelAll()
        
        // then
        await waitUntil(timeout: 0.3) { capturedEvent != nil }
        #expect(capturedEvent == nil)
        cancellable.cancel()
    }
    
    // MARK: - Event-stream leases (decision 6 / root AGENTS.md rule 7)
    
    @Test func givenTwoMembers_whenTasksPublish_thenALeaseIsAcquiredPerMember() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let tasksBox = harness.tasksBox
        let leasesBox = harness.leasesBox
        let task1 = task(id: "t1")
        let task2 = task(id: "t2")
        tasksBox.value["t1"] = task1
        tasksBox.value["t2"] = task2
        sut.didAppear()
        
        // when
        tasksSubject.send([task1, task2])
        
        // then
        await waitUntil { sut.columns.count == 2 }
        #expect(Set(leasesBox.value.keys) == ["t1", "t2"])
    }
    
    @Test func givenAMemberLeavesTheGroup_whenTasksPublishAgain_thenItsLeaseIsReleased() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let tasksBox = harness.tasksBox
        let leasesBox = harness.leasesBox
        let releasedBox = harness.releasedBox
        let task1 = task(id: "t1")
        let task2 = task(id: "t2")
        tasksBox.value["t1"] = task1
        tasksBox.value["t2"] = task2
        sut.didAppear()
        tasksSubject.send([task1, task2])
        await waitUntil { sut.columns.count == 2 }
        
        // when — task2 no longer belongs to the group
        tasksSubject.send([task1])
        
        // then — `leasesBox` only records acquisitions and never removes an entry on release, so
        // `leasesBox.value["t1"] != nil` alone would still pass even if task1's lease were incorrectly
        // released too (Codex review finding); assert `releasedBox` directly to rule that out.
        await waitUntil { sut.columns.count == 1 }
        #expect(releasedBox.value.contains("t2"))
        #expect(!releasedBox.value.contains("t1"))
        #expect(leasesBox.value["t1"] != nil)
    }
    
    @Test func givenDidDisappear_whenCalled_thenEveryLeaseIsReleasedAndReappearingReacquiresThem() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let tasksBox = harness.tasksBox
        let leasesBox = harness.leasesBox
        let releasedBox = harness.releasedBox
        let task1 = task(id: "t1")
        tasksBox.value["t1"] = task1
        sut.didAppear()
        tasksSubject.send([task1])
        await waitUntil { sut.columns.count == 1 }
        
        // when
        sut.didDisappear()
        
        // then
        #expect(releasedBox.value.contains("t1"))
        #expect(sut.columns.isEmpty == false) // `didDisappear` does not clear already-built columns
        
        // when — reappearing resubscribes and reacquires
        releasedBox.value.removeAll()
        leasesBox.value.removeAll()
        sut.didAppear()
        tasksSubject.send([task1])
        
        // then
        await waitUntil { leasesBox.value["t1"] != nil }
        #expect(leasesBox.value["t1"] != nil)
    }
    
    // MARK: - View prompt toggle
    
    @Test func givenViewPromptTapped_whenToggled_thenEveryColumnReflectsTheNewState() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let tasksBox = harness.tasksBox
        let task1 = task(id: "t1")
        tasksBox.value["t1"] = task1
        sut.didAppear()
        tasksSubject.send([task1])
        await waitUntil { sut.columns.count == 1 }
        #expect(sut.columns.first?.showPrompt == false)
        
        // when
        sut.didTapViewPrompt()
        
        // then
        #expect(sut.showPrompt)
        #expect(sut.columns.first?.showPrompt == true)
    }
    
    // MARK: - Header subtitle
    
    @Test func givenMembersWithDifferentFreedomsAndRepos_whenComputingTheHeader_thenTheSubtitleListsThem() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let tasksBox = harness.tasksBox
        let start = Date.now.addingTimeInterval(-120)
        let task1 = task(id: "t1", startedAt: start, freedom: "read_only")
        let task2 = task(id: "t2", startedAt: start.addingTimeInterval(5), freedom: "write_in_repo")
        tasksBox.value["t1"] = task1
        tasksBox.value["t2"] = task2
        sut.didAppear()
        
        // when
        tasksSubject.send([task1, task2])
        
        // then
        await waitUntil { sut.columns.count == 2 }
        #expect(sut.headerSubtitle.hasPrefix("2 agents · read_only, write_in_repo ·"))
    }
    
    // MARK: - Footer (F4-40)
    
    @Test func givenEveryMemberSharesAnEnforcementFact_whenComputingTheFooter_thenItReflectsTheSharedFact() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let snapshotsSubject = harness.snapshotsSubject
        let tasksBox = harness.tasksBox
        let sharedEnforcement: [String: JSONValue] = ["os_enforced": .bool(true)]
        let task1 = task(id: "t1")
        let task2 = task(id: "t2")
        tasksBox.value["t1"] = task1
        tasksBox.value["t2"] = task2
        sut.didAppear()
        tasksSubject.send([task1, task2])
        await waitUntil { sut.columns.count == 2 }
        #expect(sut.footerText == ParallelVM.fallbackFooter)
        
        // when — both snapshots share the same enforcement fact
        snapshotsSubject.send([
            "t1": task(id: "t1", enforcement: sharedEnforcement),
            "t2": task(id: "t2", enforcement: sharedEnforcement)
        ])
        
        // then
        await waitUntil { sut.footerText != ParallelVM.fallbackFooter }
        #expect(sut.footerText.contains("Restrictions enforced by the OS sandbox"))
    }

    // MARK: - Column loading state (Monitor piece 12, Design point 4)

    @Test func givenNoItemsAndLoadingAvailability_whenColumnBuilds_thenIsLoadingIsTrue() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let tasksBox = harness.tasksBox
        let availabilityBox = harness.availabilityBox
        let task1 = task(id: "t1")
        tasksBox.value["t1"] = task1
        availabilityBox.value["t1"] = .loading
        sut.didAppear()

        // when
        tasksSubject.send([task1])

        // then
        await waitUntil { sut.columns.count == 1 }
        #expect(sut.columns.first?.isLoading == true)
    }

    @Test func givenNoItemsAndAvailableAvailability_whenColumnBuilds_thenIsLoadingIsFalse() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let tasksBox = harness.tasksBox
        let availabilityBox = harness.availabilityBox
        let task1 = task(id: "t1")
        tasksBox.value["t1"] = task1
        availabilityBox.value["t1"] = .available
        sut.didAppear()

        // when
        tasksSubject.send([task1])

        // then — an available-but-empty log is a real empty state, never a skeleton.
        await waitUntil { sut.columns.count == 1 }
        #expect(sut.columns.first?.isLoading == false)
    }

    @Test func givenNoItemsAndUnavailableAvailability_whenColumnBuilds_thenIsLoadingIsFalse() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let tasksBox = harness.tasksBox
        let availabilityBox = harness.availabilityBox
        let task1 = task(id: "t1")
        tasksBox.value["t1"] = task1
        availabilityBox.value["t1"] = .unavailable
        sut.didAppear()

        // when
        tasksSubject.send([task1])

        // then — an unreadable log keeps its own honest empty message, never a skeleton.
        await waitUntil { sut.columns.count == 1 }
        #expect(sut.columns.first?.isLoading == false)
    }

    @Test func givenItemsAlreadyPresentEvenWhileLoading_whenColumnBuilds_thenIsLoadingIsFalse() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let tasksBox = harness.tasksBox
        let itemsBox = harness.itemsBox
        let availabilityBox = harness.availabilityBox
        let task1 = task(id: "t1")
        tasksBox.value["t1"] = task1
        itemsBox.value["t1"] = [PreviewFixtures.textItem("already have something")]
        availabilityBox.value["t1"] = .loading
        sut.didAppear()

        // when
        tasksSubject.send([task1])

        // then — real content already exists, so the shimmer never shows even while still `.loading`.
        await waitUntil { sut.columns.count == 1 }
        #expect(sut.columns.first?.isLoading == false)
    }
}
