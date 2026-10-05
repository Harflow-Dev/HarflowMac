import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbTestUtilities
import PbUI
import Testing

/// Monitor piece 7: a follow-up continues the same conversation. These build their OWN harness
/// (never `makeSUT()`) because Mockable matches FIFO — `configureStubs`'s own
/// `conversationMembers(of: .value(taskID))` stub would otherwise win over anything registered
/// after it for the same id (see `TaskDetailVMTests.swift`'s own note on `copyToPasteboard`), and
/// every one of these needs a genuinely multi-member conversation the shared harness never builds.
@MainActor
extension TaskDetailVMTests {

    func conversationTask(
        _ id: String, status: String = "completed", parentTaskID: String? = nil, spawnedBy: String? = nil,
        rootTaskID: String? = nil, sessionID: String? = "sess-1234567890", liveInput: Bool = false, minute: Int = 0
    ) -> TaskInfo {
        var object: [String: JSONValue] = [
            "task_id": .string(id), "backend": .string("claude"), "status": .string(status),
            "repo_path": .string("/repo"), "live_input": .bool(liveInput),
            "started_at": .string(String(format: "2026-09-25T10:%02d:00+00:00", minute))
        ]
        if let parentTaskID { object["parent_task_id"] = .string(parentTaskID) }
        if let spawnedBy { object["spawned_by"] = .string(spawnedBy) }
        if let rootTaskID { object["root_task_id"] = .string(rootTaskID) }
        if let sessionID { object["session_id"] = .string(sessionID) }
        return TaskInfo(.object(object))!
    }

    struct ConversationSUT {
        let sut: TaskDetailVM
        let useCase: MockTaskDetailUseCase
        let routing: MockTaskDetailRouting
        let tasksSubject: PassthroughSubject<[TaskInfo], Never>
        let membersBox: Box<[TaskInfo]>
        let eventsBox: [String: Box<[TaskEvent]>]
        let childrenBox: [String: Box<[TaskInfo]>]
        /// Counts `children(ofEach:)` calls (Codex review round 1, finding 1) — a plain call-count
        /// verify is unreliable across this harness's OWN setup-time recomputes (`Just` publishers
        /// each fire once on subscription), so a test measures a DELTA across one deliberate
        /// recompute instead, the same pattern `TaskDetailVMTests.swift`'s `recomputeCountEffect` uses.
        let childrenOfEachCallCount: Box<Int>
        /// Overridable per test (a Box, never a second `given(...)`, since Mockable's FIFO matching
        /// means a later `.value`/`.any` stub for the same member does not reliably win — see this
        /// file's header note). Defaults to "no earlier-turn child is ever outside scope".
        let cancelScopeBox: Box<(String) -> Set<String>>
        /// Same Box pattern as `cancelScopeBox`, for the same FIFO reason: `ancestors(of:)` differs
        /// by id (Codex review round 1, finding 4 — the first member's own ancestors and the
        /// current member's own ancestors are deliberately separate computations), so a test that
        /// needs a non-empty chain for one id but not another installs it here instead of a second
        /// `given(...)`. Defaults to "no ancestors for anyone".
        let ancestorsBox: Box<(String) -> [TaskInfo]>
    }

    /// One member's own stubs (lease, events, children, prompt) — split out of `makeConversationSUT`
    /// purely to keep that function under the house function-length limit; no behavior change.
    private func stubConversationMember(
        _ id: String, useCase: MockTaskDetailUseCase, membersBox: Box<[TaskInfo]>
    ) -> (events: Box<[TaskEvent]>, children: Box<[TaskInfo]>) {
        let box = Box<[TaskEvent]>([])
        let childrenForID = Box<[TaskInfo]>([])
        given(useCase).task(.value(id)).willProduce { _ in membersBox.value.first { $0.taskID == id } }
        given(useCase).detail(.value(id)).willProduce { _ in membersBox.value.first { $0.taskID == id } }
        given(useCase).children(of: .value(id)).willProduce { _ in childrenForID.value }
        given(useCase).activity(for: .value(id)).willReturn(ActivityCounts())
        given(useCase).current(for: .value(id)).willReturn(nil)
        given(useCase).prompt(for: .value(id)).willProduce { _ in Timeline.prompt(in: box.value) }
        given(useCase).eventsPath(for: .value(id)).willReturn("/tmp/\(id).events.jsonl")
        given(useCase).events(for: .value(id)).willProduce { _ in box.value }
        // The Timeline reads `items(for:)`, not `events(for:)` (Monitor piece 8, Codex review round
        // 2, finding 2) — derived from the same box so these tests' existing event fixtures still
        // drive the Timeline exactly as before.
        given(useCase).items(for: .value(id)).willProduce { _ in Timeline.items(from: box.value) }
        given(useCase).eventsAvailability(for: .value(id)).willReturn(.available)
        given(useCase).eventsAvailabilityPublisher(for: .value(id)).willReturn(Empty().eraseToAnyPublisher())
        given(useCase).itemsPublisher(for: .value(id)).willReturn(Empty().eraseToAnyPublisher())
        let lease = MockEventStreamLease()
        given(lease).taskID.willReturn(id)
        given(lease).release().willReturn()
        given(useCase).acquireEventLease(.value(id)).willReturn(lease)
        return (box, childrenForID)
    }

    /// Wires a fresh `TaskDetailVM` over a conversation whose members are `initialMembers` (oldest
    /// first), built for `openedAs` (any member id — Design point 6). Every member in
    /// `stubbedMembers` (defaults to `initialMembers`) gets its own lease/events/availability stubs
    /// from the start — pass every member a test will EVER push through `membersBox`, including ones
    /// not yet in `initialMembers`, since a test adding a brand-new follow-up mid-run needs that
    /// member's stubs to already exist before it ever appears.
    func makeConversationSUT(
        openedAs: String, initialMembers: [TaskInfo], stubbedMembers: [TaskInfo]? = nil, isWorkflowBuilder: Bool = false
    ) -> ConversationSUT {
        let useCase = MockTaskDetailUseCase()
        useCase.configurePagingDefaults()
        let routing = MockTaskDetailRouting()
        let tasksSubject = PassthroughSubject<[TaskInfo], Never>()
        let membersBox = Box(initialMembers)
        let initialMembers = stubbedMembers ?? initialMembers

        given(useCase).tasksPublisher().willReturn(tasksSubject.eraseToAnyPublisher())
        given(useCase).hasListedPublisher().willReturn(Just(true).eraseToAnyPublisher())
        given(useCase).titlesPublisher().willReturn(Empty().eraseToAnyPublisher())
        given(useCase).snapshotsPublisher().willReturn(Empty().eraseToAnyPublisher())
        given(useCase).busyPublisher().willReturn(Just(Set<String>()).eraseToAnyPublisher())
        given(useCase).outcomesPublisher().willReturn(Just([String: String]()).eraseToAnyPublisher())

        // Resolved the same way the real repository does (`Lineage.conversation(containing:in:)`)
        // against `membersBox.value` as the full current listing — never a blanket "whatever's in
        // the box regardless of id", so a retention test can shrink the listing and see `taskID`
        // stop resolving while a surviving member still does, exactly like production.
        given(useCase).conversationMembers(of: .any).willProduce { id in
            WorkflowOrchestratorConversation.members(containing: id, in: membersBox.value)
                ?? Lineage.conversation(containing: id, in: membersBox.value)?.members ?? []
        }
        // Realistic, not a stub-of-convenience: this file's own retention tests
        // (`givenTheFirstMembersRecordIsPrunedByRetentionWhileOpen…`,
        // `givenNoSurvivorRemains…`) genuinely exercise `recomputeMembersAndLeases()`'s
        // empty-members fallback, so it must resolve exactly the way production does.
        given(useCase).oldestSurvivor(among: .any).willProduce { candidates in
            Lineage.oldestSurvivor(among: candidates, in: membersBox.value)
        }
        given(useCase).title(.any).willProduce { id in "Task \(id.prefix(8))" }
        let ancestorsBox = Box<(String) -> [TaskInfo]>({ _ in [] })
        given(useCase).ancestors(of: .any).willProduce { ancestorsBox.value($0) }
        let cancelScopeBox = Box<(String) -> Set<String>>({ [$0] })
        given(useCase).cancelScope(of: .any).willProduce { cancelScopeBox.value($0) }
        given(useCase).siblings(of: .any).willReturn([])
        given(useCase).snapshot(.any).willReturn(nil)
        given(useCase).setOutcome(.any, .any).willReturn()
        given(useCase).beginTakeover(taskID: .any).willReturn()
        given(useCase).cancel(.any).willReturn(true)
        given(useCase).send(.any, text: .any).willReturn(true)
        given(useCase).resume(.any, text: .any, onResumed: .any).willProduce { id, _, onResumed in
            Task { await onResumed("\(id)-resumed") }
            return "\(id)-resumed"
        }
        given(routing).selectTask(.any).willReturn()

        var eventsBoxes: [String: Box<[TaskEvent]>] = [:]
        var childrenBoxes: [String: Box<[TaskInfo]>] = [:]
        for member in initialMembers {
            let stubs = stubConversationMember(member.taskID, useCase: useCase, membersBox: membersBox)
            eventsBoxes[member.taskID] = stubs.events
            childrenBoxes[member.taskID] = stubs.children
        }
        // One shared `LineageIndex`-style answer for every member's own children in one call
        // (Codex review round 1, finding 1) — reads the SAME per-member boxes `children(of:)` above
        // does, so a test setting `childrenBox["x"]?.value` still drives both.
        let childrenOfEachCallCount = Box<Int>(0)
        given(useCase).children(ofEach: .any).willProduce { ids in
            childrenOfEachCallCount.value += 1
            return Dictionary(ids.map { ($0, childrenBoxes[$0]?.value ?? []) }, uniquingKeysWith: { first, _ in first })
        }

        let sut = TaskDetailVM(taskID: openedAs, useCase: useCase, routing: routing, isWorkflowBuilder: isWorkflowBuilder)
        return ConversationSUT(
            sut: sut, useCase: useCase, routing: routing, tasksSubject: tasksSubject, membersBox: membersBox,
            eventsBox: eventsBoxes, childrenBox: childrenBoxes, childrenOfEachCallCount: childrenOfEachCallCount,
            cancelScopeBox: cancelScopeBox, ancestorsBox: ancestorsBox
        )
    }

    // MARK: - Any member id resolves the whole conversation (Design point 6)

    @Test func givenAnOlderMemberID_whenOpened_thenTheWholeConversationShowsWithTitleFromFirstAndStatusFromCurrent() async {
        // given — "taskA" is the first (oldest) member, "taskB" its follow-up; opened via "taskA"'s own id.
        let taskA = conversationTask("a", status: "completed", minute: 0)
        let taskB = conversationTask("b", status: "running", parentTaskID: "a", minute: 1)
        let harness = makeConversationSUT(openedAs: "a", initialMembers: [taskA, taskB])

        // when
        harness.sut.didAppear()
        harness.tasksSubject.send([taskA, taskB])
        await waitUntil { harness.sut.task != nil }

        // then
        #expect(harness.sut.task?.taskID == "b", "status/placement come from the CURRENT member")
        #expect(harness.sut.title == "Task a", "the title names the conversation from its FIRST member")
        #expect(harness.sut.turnsText == "2 turns")
    }

    @Test func givenTheNewestMemberID_whenOpened_thenItAlsoResolvesTheWholeConversation() async {
        // given — opened via "b" (the newest member) this time; Design point 6 says any member works.
        let taskA = conversationTask("a", status: "completed", minute: 0)
        let taskB = conversationTask("b", status: "completed", parentTaskID: "a", minute: 1)
        let harness = makeConversationSUT(openedAs: "b", initialMembers: [taskA, taskB])

        // when
        harness.sut.didAppear()
        harness.tasksSubject.send([taskA, taskB])
        await waitUntil { harness.sut.task != nil }

        // then
        #expect(harness.sut.task?.taskID == "b")
        #expect(harness.sut.title == "Task a")
    }

    // MARK: - Actions target the current member, never `taskID`

    @Test func givenAConversationOpenedByItsFirstMember_whenCancelling_thenTheCurrentMemberIsTargeted() async {
        // given
        let taskA = conversationTask("a", status: "completed", minute: 0)
        let taskB = conversationTask("b", status: "running", parentTaskID: "a", minute: 1)
        let harness = makeConversationSUT(openedAs: "a", initialMembers: [taskA, taskB])
        harness.sut.didAppear()
        harness.tasksSubject.send([taskA, taskB])
        await waitUntil { harness.sut.task != nil }

        // when
        harness.sut.didTapCancel()
        var capturedEvent: ViewEvent?
        let cancellable = harness.sut.objectDidPublishViewEvent.publisher.sink { capturedEvent = $0 }
        harness.sut.didTapCancel()
        await waitUntil { capturedEvent?.dialog != nil }
        guard case .dialog(let dialog) = capturedEvent else {
            Issue.record("expected a .dialog event")
            cancellable.cancel()
            return
        }
        dialog.actions.first?.action()

        // then
        await verify(harness.useCase).cancel(.value("b")).calledEventually(1, before: .seconds(5))
        verify(harness.useCase).cancel(.value("a")).called(0)
        cancellable.cancel()
    }

    // MARK: - Confirm actions target the dialog's own captured task (Codex review round 2, finding 1)

    @Test func givenTheConversationMovesOnWhileTakeoverIsConfirming_whenConfirmed_thenBeginTakeoverIsNeverCalledForTheNewCurrentMember() async {
        // given — the dialog opens for "a" (completed, the only member so far); "b" (a running
        // follow-up) arrives while it's still open, becoming the conversation's new current member.
        let taskA = conversationTask("a", status: "completed", minute: 0)
        let taskB = conversationTask("b", status: "running", parentTaskID: "a", minute: 1)
        let harness = makeConversationSUT(openedAs: "a", initialMembers: [taskA], stubbedMembers: [taskA, taskB])
        harness.sut.didAppear()
        harness.tasksSubject.send([taskA])
        await waitUntil { harness.sut.task != nil }

        var capturedEvent: ViewEvent?
        let cancellable = harness.sut.objectDidPublishViewEvent.publisher.sink { capturedEvent = $0 }
        harness.sut.didTapTakeover()
        await waitUntil { capturedEvent?.dialog != nil }
        guard case .dialog(let dialog) = capturedEvent else {
            Issue.record("expected a .dialog event")
            cancellable.cancel()
            return
        }

        // when — the conversation moves on while the dialog is still open, THEN it is confirmed.
        harness.membersBox.value = [taskA, taskB]
        harness.tasksSubject.send([taskA, taskB])
        await waitUntil { harness.sut.task?.taskID == "b" }
        dialog.actions.first?.action()

        // then — never silently takes over "b"; the dialog described "a", which is now stale, so
        // the confirm refuses outright rather than acting on either task.
        try? await Task.sleep(for: .milliseconds(50))
        verify(harness.useCase).beginTakeover(taskID: .any).called(0)
        verify(harness.useCase).setOutcome(.value("b"), .value("The conversation moved on — review and try again.")).called(1)
        cancellable.cancel()
    }

    // MARK: - Cancel scope honesty (Review round 1 item 5 / round 2)

    @Test func givenAnEarlierTurnsChildStillRunning_whenCancelling_thenTheDialogNamesItAsNotCancelledByThis() async {
        // given — "a" (the first, earlier turn) spawned "child-x", still running; cancelling "b"
        // (the current turn) never reaches it via `spawned_by`. `cancelScopeBox` is wired to the
        // REAL `Lineage.cancelScope(of:in:)` (Codex review round 1, finding 5) — the production
        // code no longer inspects `children(of:)` at all for this, only `cancelScope(of:)` per
        // earlier member plus `task(_:)` to check whether a candidate is still running.
        let taskA = conversationTask("a", status: "completed", minute: 0)
        let taskB = conversationTask("b", status: "running", parentTaskID: "a", minute: 1)
        let harness = makeConversationSUT(openedAs: "a", initialMembers: [taskA, taskB])
        let childX = conversationTask("child-x", status: "running", spawnedBy: "a", minute: 2)
        let allTasks = [taskA, taskB, childX]
        given(harness.useCase).task(.value("child-x")).willReturn(childX)
        harness.cancelScopeBox.value = { id in Lineage.cancelScope(of: id, in: allTasks) }
        harness.sut.didAppear()
        harness.tasksSubject.send([taskA, taskB])
        await waitUntil { harness.sut.task != nil }

        // when
        var capturedEvent: ViewEvent?
        let cancellable = harness.sut.objectDidPublishViewEvent.publisher.sink { capturedEvent = $0 }
        harness.sut.didTapCancel()

        // then
        await waitUntil { capturedEvent?.dialog != nil }
        guard case .dialog(let dialog) = capturedEvent else {
            Issue.record("expected a .dialog event")
            cancellable.cancel()
            return
        }
        #expect(dialog.description == "polybridge stops the run and, best-effort, every live sub-task it started."
            + " Still running from earlier turns (not cancelled by this): Task child-x.")
        cancellable.cancel()
    }

    @Test func givenARootOnlyLinkedDescendantOfAnEarlierTurn_whenCancelling_thenItCountsAsInScopeAndIsNotNamed() async {
        // given — "child-r" is spawned by "a" (an earlier turn) but its `root_task_id` names "b"
        // (the current task), so the real cascade DOES reach it via `root_task_id` even though it
        // also shows up in "a"'s own `spawned_by` closure; it must never be listed as "not
        // cancelled by this" even though it looks like an earlier turn's own descendant.
        let taskA = conversationTask("a", status: "completed", minute: 0)
        let taskB = conversationTask("b", status: "running", parentTaskID: "a", minute: 1)
        let harness = makeConversationSUT(openedAs: "a", initialMembers: [taskA, taskB])
        let childR = conversationTask("child-r", status: "running", spawnedBy: "a", rootTaskID: "b", minute: 2)
        let allTasks = [taskA, taskB, childR]
        given(harness.useCase).task(.value("child-r")).willReturn(childR)
        harness.cancelScopeBox.value = { id in Lineage.cancelScope(of: id, in: allTasks) }
        harness.sut.didAppear()
        harness.tasksSubject.send([taskA, taskB])
        await waitUntil { harness.sut.task != nil }

        // when
        var capturedEvent: ViewEvent?
        let cancellable = harness.sut.objectDidPublishViewEvent.publisher.sink { capturedEvent = $0 }
        harness.sut.didTapCancel()

        // then
        await waitUntil { capturedEvent?.dialog != nil }
        guard case .dialog(let dialog) = capturedEvent else {
            Issue.record("expected a .dialog event")
            cancellable.cancel()
            return
        }
        #expect(dialog.description == "polybridge stops the run and, best-effort, every live sub-task it started.")
        cancellable.cancel()
    }

    @Test func givenAnEarlierTurnsGrandchildStillRunning_whenCancelling_thenTheDialogNamesItEvenThoughItIsNotADirectChild() async {
        // given — Codex review round 1, finding 5: "earlier turn A → completed X → running Y" must
        // still name Y, even though Y is A's GRANDCHILD (via X), not A's own direct child. The old
        // implementation only ever looked at `children(of:)` (direct children), which would have
        // missed this entirely.
        let taskA = conversationTask("a", status: "completed", minute: 0)
        let taskB = conversationTask("b", status: "running", parentTaskID: "a", minute: 1)
        let harness = makeConversationSUT(openedAs: "a", initialMembers: [taskA, taskB])
        let taskX = conversationTask("x", status: "completed", spawnedBy: "a", minute: 2)
        let taskY = conversationTask("y", status: "running", spawnedBy: "x", minute: 3)
        let allTasks = [taskA, taskB, taskX, taskY]
        given(harness.useCase).task(.value("x")).willReturn(taskX)
        given(harness.useCase).task(.value("y")).willReturn(taskY)
        harness.cancelScopeBox.value = { id in Lineage.cancelScope(of: id, in: allTasks) }
        harness.sut.didAppear()
        harness.tasksSubject.send([taskA, taskB])
        await waitUntil { harness.sut.task != nil }

        // when
        var capturedEvent: ViewEvent?
        let cancellable = harness.sut.objectDidPublishViewEvent.publisher.sink { capturedEvent = $0 }
        harness.sut.didTapCancel()

        // then
        await waitUntil { capturedEvent?.dialog != nil }
        guard case .dialog(let dialog) = capturedEvent else {
            Issue.record("expected a .dialog event")
            cancellable.cancel()
            return
        }
        #expect(dialog.description == "polybridge stops the run and, best-effort, every live sub-task it started."
            + " Still running from earlier turns (not cancelled by this): Task y.")
        cancellable.cancel()
    }

    // MARK: - Breadcrumbs vs. Inspector ancestors (Codex review round 1, finding 4)

    @Test func givenAnUnrelatedTaskResumedAnEarlierMember_whenShown_thenBreadcrumbsStayFirstButInspectorReflectsCurrent() async {
        // given — "p" spawned "a" (the conversation's first member, its own placement in the
        // sidebar's tree); an UNRELATED task "q" later resumed "a" into "b" (the current member),
        // so "b"'s own `spawned_by` chain is "q", not "p" at all. Cancelling "p" never reaches "b" —
        // the breadcrumb naming "p" must not imply otherwise, and the Inspector's own lineage must
        // describe "b"'s real relationship to "q", not "a"'s to "p".
        let taskP = conversationTask("p", status: "completed", minute: -2)
        let taskQ = conversationTask("q", status: "completed", minute: -1)
        let taskA = conversationTask("a", status: "completed", spawnedBy: "p", minute: 0)
        let taskB = conversationTask("b", status: "completed", parentTaskID: "a", spawnedBy: "q", minute: 1)
        let harness = makeConversationSUT(openedAs: "a", initialMembers: [taskA, taskB])
        given(harness.useCase).task(.value("p")).willReturn(taskP)
        given(harness.useCase).task(.value("q")).willReturn(taskQ)
        harness.ancestorsBox.value = { id in
            switch id {
            case "a": [taskP]
            case "b": [taskQ]
            default: []
            }
        }
        harness.sut.didAppear()
        harness.tasksSubject.send([taskA, taskB])
        await waitUntil { harness.sut.task != nil }

        // then — breadcrumbs are the conversation's own placement (first member "a" → "p").
        #expect(harness.sut.ancestorCrumbs.map(\.id) == ["p"])
        // then — the Inspector describes the CURRENT member "b"'s real chain ("q"), never "p".
        #expect(harness.sut.inspectorModel?.ancestors.map(\.task.taskID) == ["q"])
    }

    // MARK: - Continue does not navigate (Design point 7)

    @Test func givenAnEligibleContinue_whenSubmitted_thenItTargetsTheCurrentMemberAndNeverSelectsTheNewTask() async {
        // given
        let taskA = conversationTask("a", status: "completed", minute: 0)
        let harness = makeConversationSUT(openedAs: "a", initialMembers: [taskA])
        harness.sut.didAppear()
        harness.tasksSubject.send([taskA])
        await waitUntil { harness.sut.task != nil }

        // when
        #expect(harness.sut.submitMessage("one more thing"))

        // then
        await verify(harness.useCase).resume(.value("a"), text: .value("one more thing"), onResumed: .any).calledEventually(1, before: .seconds(5))
        try? await Task.sleep(for: .milliseconds(50))
        verify(harness.routing).selectTask(.any).called(0)
    }

    // MARK: - Retention while open (Review round 1, item 4)

    @Test func givenTheFirstMembersRecordIsPrunedByRetentionWhileOpen_whenTheListingUpdates_thenTheSurvivingMemberKeepsTheConversationShowing() async {
        // given — opened via "a" (its own `taskID`, the conversation's first member); "b" is its
        // follow-up. Both are listed, so `lastKnownMemberIDsOldestFirst` records ["a", "b"].
        let taskA = conversationTask("a", status: "completed", minute: 0)
        let taskB = conversationTask("b", status: "running", parentTaskID: "a", minute: 1)
        let harness = makeConversationSUT(openedAs: "a", initialMembers: [taskA, taskB])
        harness.sut.didAppear()
        harness.tasksSubject.send([taskA, taskB])
        await waitUntil { harness.sut.task?.taskID == "b" }

        // when — retention prunes "a"'s own record; only "b" remains in the listing. Naively,
        // `conversationMembers(of: "a")` now resolves to `[]` (as it genuinely does in production).
        harness.membersBox.value = [taskB]
        harness.tasksSubject.send([taskB])

        // then — the VM still shows the live conversation (through survivor "b"), never "not in
        // polybridge's records"; actions still target the current task.
        await waitUntil { harness.sut.hasListed }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.sut.task != nil, "the conversation must not read as gone")
        #expect(harness.sut.task?.taskID == "b")
        var capturedEvent: ViewEvent?
        let cancellable = harness.sut.objectDidPublishViewEvent.publisher.sink { capturedEvent = $0 }
        harness.sut.didTapCancel()
        await waitUntil { capturedEvent?.dialog != nil }
        guard case .dialog(let dialog) = capturedEvent else {
            Issue.record("expected a .dialog event")
            cancellable.cancel()
            return
        }
        dialog.actions.first?.action()
        await verify(harness.useCase).cancel(.value("b")).calledEventually(1, before: .seconds(5))
        cancellable.cancel()
    }

    @Test func givenNoSurvivorRemains_whenTheListingUpdates_thenTheTaskGenuinelyReadsAsMissing() async {
        // given — a regression guard: retention truly removing the WHOLE conversation (no survivor
        // at all) must still read as missing, not silently keep stale state around.
        let taskA = conversationTask("a", status: "completed", minute: 0)
        let harness = makeConversationSUT(openedAs: "a", initialMembers: [taskA])
        harness.sut.didAppear()
        harness.tasksSubject.send([taskA])
        await waitUntil { harness.sut.task != nil }

        // when
        harness.membersBox.value = []
        harness.tasksSubject.send([])

        // then
        await waitUntil { harness.sut.task == nil }
        #expect(harness.sut.task == nil)
    }

    @Test func givenABranchingConversationOpenedByALaterMember_whenItsFirstMemberIsPrunedByRetention_thenItFollowsTheSameSurvivorTheSidebarWould() async {
        // given — Codex review round 2, finding 2: "a" resumed into BOTH "b" and "c" (a branching
        // conversation); this VM is opened via "c" — a LATER member, never the conversation's own
        // first/identity id ("a"). `Lineage.oldestSurvivor` is the SAME deterministic rule the
        // sidebar uses (Codex review round 1, finding 3), so both must land on the same survivor
        // once "a" is pruned — never falling back on "c"'s own now-orphaned singleton conversation,
        // which is what querying `conversationMembers(of: taskID)` forever would have done.
        let taskA = conversationTask("a", status: "completed", minute: 0)
        let taskB = conversationTask("b", status: "completed", parentTaskID: "a", minute: 1)
        let taskC = conversationTask("c", status: "completed", parentTaskID: "a", minute: 2)
        let harness = makeConversationSUT(openedAs: "c", initialMembers: [taskA, taskB, taskC])
        harness.sut.didAppear()
        harness.tasksSubject.send([taskA, taskB, taskC])
        await waitUntil { harness.sut.task?.taskID == "c" }
        #expect(harness.sut.turnsText == "3 turns")

        // when — retention prunes "a"; "b" and "c" both survive, each now its own singleton
        // conversation (their shared link to "a" is gone with it).
        harness.membersBox.value = [taskB, taskC]
        harness.tasksSubject.send([taskB, taskC])

        // then — this VM (opened through "c") follows "b" — the OLDEST surviving member of the
        // whole conversation it used to belong to.
        await waitUntil { harness.sut.task?.taskID == "b" }
        #expect(harness.sut.conversationMembers.map(\.taskID) == ["b"])
    }

    // MARK: - Timeline concatenation order and turn separators

    @Test func givenTwoMembers_whenBuildingTheTimeline_thenRowsConcatenateOldestFirstWithASeparatorAheadOfTheFollowUp() async {
        // given
        let taskA = conversationTask("a", status: "completed", minute: 0)
        let taskB = conversationTask("b", status: "completed", parentTaskID: "a", minute: 1)
        let harness = makeConversationSUT(openedAs: "a", initialMembers: [taskA, taskB])
        harness.eventsBox["a"]?.value = [
            TaskEvent(line: #"{"v":1,"seq":0,"kind":"task_started","prompt":"fix the bug"}"#)!,
            TaskEvent(line: #"{"v":1,"seq":1,"kind":"assistant_text","text":"Looked at the failing test."}"#)!
        ]
        harness.eventsBox["b"]?.value = [
            TaskEvent(line: #"{"v":1,"seq":0,"kind":"task_started","prompt":"also add a test"}"#)!,
            TaskEvent(line: #"{"v":1,"seq":1,"kind":"assistant_text","text":"Added the missing test."}"#)!
        ]

        // when
        harness.sut.didAppear()
        harness.tasksSubject.send([taskA, taskB])
        harness.sut.timelineModel.onLoadMore?()
        await waitUntil { harness.sut.task != nil }

        // then
        let rows = harness.sut.timelineModel.rows
        await waitUntil { rows.count >= 5 }
        let taskIDs = harness.sut.timelineModel.rows.map(\.taskID)
        #expect(taskIDs.prefix(2) == ["a", "a"], "the first member's own turn comes first")
        let separatorIndex = harness.sut.timelineModel.rows.firstIndex { if case .separator = $0.kind { return true }; return false }
        #expect(separatorIndex != nil)
        if let separatorIndex, case .separator(let text) = harness.sut.timelineModel.rows[separatorIndex].kind {
            #expect(text == "also add a test")
        }
    }

    // MARK: - Summary: current member's own answer, edited files across every turn

    @Test func givenFilesEditedInEarlierAndLaterTurns_whenBuildingTheSummary_thenBothShowAndTheAnswerIsTheCurrentMembers() async {
        // given
        let taskA = conversationTask("a", status: "completed", minute: 0)
        let taskB = conversationTask("b", status: "completed", parentTaskID: "a", minute: 1)
        let harness = makeConversationSUT(openedAs: "a", initialMembers: [taskA, taskB])
        harness.eventsBox["a"]?.value = [
            TaskEvent(line: #"{"v":1,"seq":0,"kind":"tool_call","call_id":"c1","tool":"Edit","category":"edit","input_preview":"","path":"/repo/a.swift"}"#)!,
            TaskEvent(line: #"{"v":1,"seq":1,"kind":"tool_result","call_id":"c1","ok":true,"output_tail":""}"#)!
        ]
        harness.eventsBox["b"]?.value = [
            TaskEvent(line: #"{"v":1,"seq":0,"kind":"tool_call","call_id":"c1","tool":"Edit","category":"edit","input_preview":"","path":"/repo/b.swift"}"#)!,
            TaskEvent(line: #"{"v":1,"seq":1,"kind":"tool_result","call_id":"c1","ok":true,"output_tail":""}"#)!
        ]
        given(harness.useCase).snapshot(.value("b")).willReturn(conversationTask("b", status: "completed"))

        // when
        harness.sut.didAppear()
        harness.tasksSubject.send([taskA, taskB])
        await waitUntil { harness.sut.task != nil }
        // Summary only recomputes while shown (Monitor piece 8, Codex review round 2, finding 2).
        harness.sut.didSelectTab(.summary)
        await waitUntil { !harness.sut.summaryModel.editedFiles.isEmpty }

        // then
        #expect(Set(harness.sut.summaryModel.editedFiles.map(\.path)) == ["a.swift", "b.swift"])
        await waitUntil { !harness.sut.conversationLoading }
        harness.sut.didSelectTab(.summary)
        #expect(harness.sut.summaryModel.editedFilesAvailability == .available)
    }
}

// MARK: - Exact execution detail

extension TaskDetailVMTests {
    @Test func givenWorkflowResumeChain_whenOlderChildOpened_thenShowsThatExecutionOnly() throws {
        // given
        var oldRaw = conversationTask("old").raw
        oldRaw["workflow_run_id"] = .string("workflow")
        var nextRaw = conversationTask("next", parentTaskID: "old", minute: 1).raw
        nextRaw["workflow_run_id"] = .string("workflow")
        let old = try #require(TaskInfo(.object(oldRaw)))
        let next = try #require(TaskInfo(.object(nextRaw)))
        let harness = makeConversationSUT(openedAs: "old", initialMembers: [old, next])
        // when
        harness.sut.recomputeMembersAndLeases()
        // then
        #expect(harness.sut.conversationMembers.map(\.taskID) == ["old"])
        #expect(harness.sut.currentTaskID == "old")
    }
}
