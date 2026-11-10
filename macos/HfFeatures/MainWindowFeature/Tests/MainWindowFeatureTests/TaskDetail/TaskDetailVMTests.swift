import Combine
import Foundation
import HfCommon
import HfRepository
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import Mockable
import MonitorCore
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
        summary: String? = nil, enforcement: [String: JSONValue]? = nil, resumeCommand: String? = nil
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
        if let resumeCommand { object["resume_command"] = .string(resumeCommand) }
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
        let outcomesSubject: CurrentValueSubject<[String: String], Never>
        let itemsSubject: PassthroughSubject<[TimelineItem], Never>
        let eventsAvailabilitySubject: PassthroughSubject<EventAvailability, Never>
        let lease: MockEventStreamLease
        let detailBox: Box<TaskInfo?>
        let snapshotBox: Box<TaskInfo?>
        let eventsBox: Box<[TaskEvent]>
        let eventsAvailabilityBox: Box<EventAvailability>
        let ancestorsBox: Box<[TaskInfo]>
        let refreshSnapshotEffect: Box<(() -> Void)?>
        let childrenBox: Box<[TaskInfo]>
        let itemsOverride: Box<[TimelineItem]?>
        let recomputeCountEffect: Box<(() -> Void)?>
        let observationBox: Box<EventObservationFrame?>
        let observationSubject: PassthroughSubject<EventObservationFrame, Never>
        let recoveryBox: Box<RecoveredTranscriptFrame>
        let recoverySubject: PassthroughSubject<RecoveredTranscriptFrame, Never>
        let requestBox: Box<TaskRequestReadState>
        let requestSubject: PassthroughSubject<TaskRequestReadState, Never>
        let callerApprovalBox: Box<(any CallerApprovalUseCase)?>
    }

    /// The fixtures `makeSUT` builds before wiring up `useCase`'s stubs — split out purely to keep
    /// `makeSUT`/`configureStubs` each under the house function-length limit; no behavior change.
    struct Fixtures {
        let successorObservationEffect = Box<((String) throws -> Bool)?>(nil)
        let continuationOwner = Box<any TaskContinuationRepository>(NullTaskContinuationRepository())
        let continuationRuntime = Box<QualificationRuntimeToken?>(nil)
        let continuationSupport = Box<Bool>(false)
        let newTaskCount = Box<Int>(0)
        let conversationMembersProvider = Box<((String) -> [TaskInfo])?>(nil)
        let taskProvider = Box<((String) -> TaskInfo?)?>(nil)
        let statusReadProvider = Box<((String) -> TaskSnapshotReadOutcome?)?>(nil)
        let statusReadSubject = PassthroughSubject<Void, Never>()
        let stoppingQuery = Box<((String) -> Bool)?>(nil)
        let stoppingPublisher = Box<AnyPublisher<Void, Never>?>(nil)
        let cancelEffect = Box<((String) -> Bool)?>(nil)
        let stopping = Box<Bool>(false)
        let stoppingSubject = PassthroughSubject<Void, Never>()
        let tasksSubject = PassthroughSubject<[TaskInfo], Never>()
        let hasListedSubject = PassthroughSubject<Bool, Never>()
        let titlesSubject = PassthroughSubject<[String: String], Never>()
        let snapshotsSubject = PassthroughSubject<[String: TaskInfo], Never>()
        let busySubject = PassthroughSubject<Set<String>, Never>()
        // Replays its latest value to a new subscriber, like the real `TaskActionRepository`'s
        // `@Subjected` outcomes — so a fresh VM sees an outcome stored before it existed.
        let outcomesSubject = CurrentValueSubject<[String: String], Never>([:])
        let itemsSubject = PassthroughSubject<[TimelineItem], Never>()
        let eventsAvailabilitySubject = PassthroughSubject<EventAvailability, Never>()

        let detailBox = Box<TaskInfo?>(nil)
        let snapshotBox = Box<TaskInfo?>(nil)
        let eventsBox = Box<[TaskEvent]>([])
        let eventsAvailabilityBox = Box<EventAvailability>(.available)
        let ancestorsBox = Box<[TaskInfo]>([])
        let childrenBox = Box<[TaskInfo]>([])
        // Test-installable hook consulted by the single `refreshSnapshot` stub below — re-stubbing
        // the same member a second time is FIFO/unreliable (see `ParallelVMTests`'s `Box` note), so
        // a test that needs to observe/react to a call installs a closure here instead of calling
        // `given(...)` again.
        let refreshSnapshotEffect = Box<(() -> Void)?>(nil)
        // Defaults to a real rebuild of `eventsBox` (matching what the real repository's own
        // `TimelineBuilder` would settle on for the same events), same FIFO reason as above — a test
        // proving the Timeline is built from `items(for:)`/`itemsPublisher(for:)` and NOT from
        // `Timeline.items(from: events(for:))` (Monitor piece 8, Codex review round 2, finding 2)
        // sets this to something deliberately different from `eventsBox`'s own content.
        let itemsOverride = Box<[TimelineItem]?>(nil)
        /// A hook run on every `useCase.title(_:)` call — `recompute()`'s own unconditional
        /// `title = useCase.title(firstMember.taskID)` line, so a test counting invocations of this
        /// hook is counting `recompute()` calls (Monitor piece 11's snapshot-publication dedup test).
        /// Same FIFO reason as `refreshSnapshotEffect` above for why this is a hook installed here
        /// rather than a re-stubbed `given(...)` call in the test itself.
        let recomputeCountEffect = Box<(() -> Void)?>(nil)
        let observationBox = Box<EventObservationFrame?>(nil)
        let observationSubject = PassthroughSubject<EventObservationFrame, Never>()
        let recoveryBox = Box(RecoveredTranscriptFrame())
        let recoverySubject = PassthroughSubject<RecoveredTranscriptFrame, Never>()
        let requestBox = Box<TaskRequestReadState>(.notRequested)
        let requestSubject = PassthroughSubject<TaskRequestReadState, Never>()
        let callerApprovalBox = Box<(any CallerApprovalUseCase)?>(nil)
    }

    private func configureObservationStubs(useCase: MockTaskDetailUseCase, taskID: String, fixtures: Fixtures) {
        given(useCase).observation(for: .value(taskID)).willProduce { _ in
            fixtures.observationBox.value ?? FeatureObservationFixture.frame(id: taskID,
                events: fixtures.eventsBox.value,
                items: fixtures.itemsOverride.value ?? Timeline.items(from: fixtures.eventsBox.value),
                availability: fixtures.eventsAvailabilityBox.value)
        }
        given(useCase).observationPublisher(for: .value(taskID)).willProduce { [callOrder] _ in
            callOrder.value.append("itemsPublisher")
            return Publishers.Merge(fixtures.observationSubject.eraseToAnyPublisher(),
                Publishers.Merge(fixtures.itemsSubject.map { items in fixtures.itemsOverride.value = items },
                    fixtures.eventsAvailabilitySubject.map { availability in fixtures.eventsAvailabilityBox.value = availability })
                    .map { _ in useCase.observation(for: taskID) }
.eraseToAnyPublisher())
.eraseToAnyPublisher()
        }
        given(useCase).recoveredTranscript(for: .value(taskID)).willProduce { _ in fixtures.recoveryBox.value }
        given(useCase).recoveredTranscriptPublisher(for: .value(taskID)).willReturn(fixtures.recoverySubject.eraseToAnyPublisher())
        given(useCase).requestState(for: .value(taskID)).willProduce { _ in fixtures.requestBox.value }
        given(useCase).requestPublisher(for: .value(taskID)).willReturn(fixtures.requestSubject.eraseToAnyPublisher())
    }

    @discardableResult
    func configureStubs(useCase: MockTaskDetailUseCase, routing: MockTaskDetailRouting, taskID: String, fixtures: Fixtures) -> MockEventStreamLease {
        configureObservationStubs(useCase: useCase, taskID: taskID, fixtures: fixtures)
        configureStatusReadStubs(useCase: useCase, taskID: taskID, fixtures: fixtures)
        configureContinuationStubs(useCase: useCase, routing: routing, fixtures: fixtures)
        given(useCase).tasksPublisher().willReturn(fixtures.tasksSubject.eraseToAnyPublisher())
        given(useCase).hasListedPublisher().willReturn(fixtures.hasListedSubject.eraseToAnyPublisher())
        given(useCase).titlesPublisher().willReturn(fixtures.titlesSubject.eraseToAnyPublisher())
        given(useCase).snapshotsPublisher().willReturn(fixtures.snapshotsSubject.eraseToAnyPublisher())
        given(useCase).isStopping(.any).willProduce { id in fixtures.stoppingQuery.value?(id) ?? fixtures.stopping.value }
        given(useCase).stoppingChangesPublisher().willReturn(fixtures.stoppingPublisher.value ?? fixtures.stoppingSubject.eraseToAnyPublisher())
        given(useCase).busyPublisher().willReturn(fixtures.busySubject.eraseToAnyPublisher())
        given(useCase).outcomesPublisher().willReturn(fixtures.outcomesSubject.eraseToAnyPublisher())
        given(useCase).itemsPublisher(for: .value(taskID)).willProduce { [callOrder] _ in
            callOrder.value.append("itemsPublisher")
            return fixtures.itemsSubject.eraseToAnyPublisher()
        }
        given(useCase).eventsAvailabilityPublisher(for: .value(taskID)).willReturn(fixtures.eventsAvailabilitySubject.eraseToAnyPublisher())

        given(useCase).detail(.value(taskID)).willProduce { _ in fixtures.detailBox.value }

        given(useCase).title(.any).willProduce { id in
            fixtures.recomputeCountEffect.value?()
            return "Task \(id.prefix(8))"
        }
        given(useCase).ancestors(of: .any).willProduce { _ in fixtures.ancestorsBox.value }
        given(useCase).children(of: .value(taskID)).willProduce { _ in fixtures.childrenBox.value }
        // Default: single-member scenario, so every requested id (there is only ever the one) maps
        // to the same `childrenBox` `children(of:)` already answers with.
        given(useCase).children(ofEach: .any).willProduce { ids in
            Dictionary(ids.map { ($0, fixtures.childrenBox.value) }, uniquingKeysWith: { first, _ in first })
        }
        given(useCase).siblings(of: .value(taskID)).willReturn([])
        // Default: a single-member conversation of exactly the fixed `taskID` — the same task every
        // existing (pre-piece-7) test already sets up via `detailBox`, so every property that now
        // resolves through `conversationMembers` reduces to the old single-task behaviour unless a
        // test overrides this stub for its own multi-member scenario.
        given(useCase).conversationMembers(of: .value(taskID)).willProduce { id in
            fixtures.conversationMembersProvider.value?(id) ?? fixtures.detailBox.value.map { [$0] } ?? []
        }
        // Default: no earlier-turn child is ever outside scope — a singleton conversation's cancel
        // scope is just the task itself, unless a test overrides this for its own scenario.
        given(useCase).cancelScope(of: .any).willProduce { [$0] }
        // Default: no survivor — `recomputeMembersAndLeases()` calls this whenever conversation
        // resolution comes back empty (routinely, at VM init before the first listing arrives), so
        // every test needs SOME stub here even when it never exercises retention itself.
        given(useCase).oldestSurvivor(among: .any).willReturn(nil)
        given(useCase).callerApprovalUseCase().willProduce { fixtures.callerApprovalBox.value }

        given(useCase).snapshot(.value(taskID)).willProduce { _ in fixtures.snapshotBox.value }
        given(useCase).refreshSnapshot(.value(taskID)).willProduce { _ in fixtures.refreshSnapshotEffect.value?() }

        let lease = MockEventStreamLease()
        given(lease).taskID.willReturn(taskID)
        given(lease).release().willReturn()
        given(useCase).acquireEventLease(.value(taskID)).willProduce { [callOrder] _ in
            callOrder.value.append("acquireEventLease")
            return lease
        }
        given(useCase).items(for: .value(taskID)).willProduce { _ in
            fixtures.itemsOverride.value ?? Timeline.items(from: fixtures.eventsBox.value)
        }
        given(useCase).events(for: .value(taskID)).willProduce { _ in fixtures.eventsBox.value }
        given(useCase).eventsAvailability(for: .value(taskID)).willProduce { _ in fixtures.eventsAvailabilityBox.value }
        given(useCase).activity(for: .value(taskID)).willReturn(ActivityCounts())
        given(useCase).current(for: .value(taskID)).willReturn(nil)
        given(useCase).prompt(for: .value(taskID)).willReturn(nil)

        given(useCase).cancel(.any).willProduce { fixtures.cancelEffect.value?($0) ?? true }
        given(useCase).send(.any, text: .any).willReturn(true)
        // Routing happens via `onResumed` (item 4), not the return value. Mockable producers are
        // synchronous, so the async callback runs in a Task; tests poll for its effect.
        given(useCase).resume(.any, text: .any, onResumed: .any).willProduce { _, _, onResumed in
            Task { await onResumed("newTaskID") }
            return "newTaskID"
        }
        given(useCase).beginTakeover(taskID: .any).willReturn()
        given(useCase).setOutcome(.any, .any).willReturn()
        stubTopBarRouting(routing)
        // No default `copyToPasteboard` stub: Mockable matches FIFO (first-added wins on overlap),
        // so a blanket `.any` stub here would shadow any test-specific `.willReturn(false)` added
        // later (see `TaskDetailVMTests+Actions.swift`'s copy-resume-command tests, each of which
        // stubs it explicitly for the outcome it needs).
        return lease
    }

    private func configureContinuationStubs(useCase: MockTaskDetailUseCase, routing: MockTaskDetailRouting, fixtures: Fixtures) {
        given(useCase).continuationOwner().willProduce { fixtures.continuationOwner.value }
        given(useCase).continuationRuntime().willProduce { fixtures.continuationRuntime.value }
        given(useCase).continuationSupport(runtime: .any).willProduce { _ in fixtures.continuationSupport.value }
        given(routing).showNewTask().willProduce { fixtures.newTaskCount.value += 1 }
        given(routing).selectTask(.any).willReturn()
    }

    private func configureStatusReadStubs(useCase: MockTaskDetailUseCase, taskID: String, fixtures: Fixtures) {
        given(useCase).task(.any).willProduce { id in
            if let provider = fixtures.taskProvider.value { return provider(id) }
            return id == taskID ? fixtures.detailBox.value : nil
        }
        // Action-focused fixtures explicitly model an admitted successful status read by default.
        // Failure/unread tests replace the provider without overlapping Mockable stubs.
        given(useCase).statusReadOutcome(.any).willProduce { id in
            if let provider = fixtures.statusReadProvider.value { return provider(id) }
            return fixtures.detailBox.value.map { TaskSnapshotReadOutcome(revision: 1, task: $0) }
        }
        given(useCase).statusReadChangesPublisher().willReturn(fixtures.statusReadSubject.eraseToAnyPublisher())
    }

    @discardableResult
    func makeSUT(taskID: String = "abc12345", isWorkflowBuilder: Bool = false, chrome: TaskDetailChrome = .group,
                 scheduler: any Scheduling = NullScheduling(), fixtures: Fixtures = Fixtures()) -> SUT {
        let useCase = MockTaskDetailUseCase()
        let routing = MockTaskDetailRouting()
        let lease = configureStubs(useCase: useCase, routing: routing, taskID: taskID, fixtures: fixtures)
        useCase.configurePagingDefaults(includeObservationDefaults: false, includeContinuationDefaults: false,
                                       successorObservation: { try fixtures.successorObservationEffect.value?($0) ?? false })

        let sut = TaskDetailVM(taskID: taskID, useCase: useCase, routing: routing,
                               continuityHistory: TaskContinuityHistoryStore(), chrome: isWorkflowBuilder ? .embedded : chrome,
                               scheduler: scheduler, isWorkflowBuilder: isWorkflowBuilder)
        return SUT(
            sut: sut, useCase: useCase, routing: routing, tasksSubject: fixtures.tasksSubject,
            hasListedSubject: fixtures.hasListedSubject, snapshotsSubject: fixtures.snapshotsSubject,
            busySubject: fixtures.busySubject, outcomesSubject: fixtures.outcomesSubject,
            itemsSubject: fixtures.itemsSubject, eventsAvailabilitySubject: fixtures.eventsAvailabilitySubject,
            lease: lease,
            detailBox: fixtures.detailBox, snapshotBox: fixtures.snapshotBox,
            eventsBox: fixtures.eventsBox, eventsAvailabilityBox: fixtures.eventsAvailabilityBox,
            ancestorsBox: fixtures.ancestorsBox,
            refreshSnapshotEffect: fixtures.refreshSnapshotEffect,
            childrenBox: fixtures.childrenBox,
            itemsOverride: fixtures.itemsOverride,
            recomputeCountEffect: fixtures.recomputeCountEffect,
            observationBox: fixtures.observationBox, observationSubject: fixtures.observationSubject,
            recoveryBox: fixtures.recoveryBox, recoverySubject: fixtures.recoverySubject,
            requestBox: fixtures.requestBox, requestSubject: fixtures.requestSubject,
            callerApprovalBox: fixtures.callerApprovalBox
        )
    }
    
    // MARK: - Snapshot publication dedup (Monitor piece 11, Plan review round 1 item 3)

    @Test
    func givenASnapshotsPublicationThatDoesNotTouchAnyMember_whenPublished_thenNoRecomputeHappens() async {
        // given — `snapshotsPublisher()` covers every task in the system; an update naming some
        // OTHER task must never trigger a recompute of a screen showing this one. The count is
        // installed from the start and the assertion is a DELTA (Monitor piece 11): `didAppear()`/
        // `tasksSubject.send(...)` themselves schedule their own recomputes (including the shared
        // `outcomesPublisher` `CurrentValueSubject`'s initial replay), so an absolute "count == 0"
        // taken right after `sut.task != nil` becomes true would measure that startup noise, not
        // whether the snapshot publish itself triggered anything.
        let harness = makeSUT()
        let sut = harness.sut
        let running = task(status: "running")
        harness.detailBox.value = running
        let recomputeCount = Box<Int>(0)
        harness.recomputeCountEffect.value = { recomputeCount.value += 1 }
        sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { sut.task != nil }
        // Let every still-pending scheduled recompute from setup actually run before taking the
        // baseline.
        await waitUntil(timeout: 0.2) { false }
        let baseline = recomputeCount.value

        // when — an unrelated task's snapshot changes.
        harness.snapshotsSubject.send(["some-other-task": task(id: "some-other-task")])

        // then — no recompute follows within a generous window (this `waitUntil` always runs its
        // full timeout here, since the condition it polls for must never become true).
        await waitUntil(timeout: 0.3) { recomputeCount.value > baseline }
        #expect(recomputeCount.value == baseline)
    }

    @Test
    func givenASnapshotsPublicationThatTouchesTheCurrentMember_whenPublished_thenARecomputeFollows() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let running = task(status: "running")
        harness.detailBox.value = running
        let recomputeCount = Box<Int>(0)
        harness.recomputeCountEffect.value = { recomputeCount.value += 1 }
        sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { sut.task != nil }
        await waitUntil(timeout: 0.2) { false }
        let baseline = recomputeCount.value

        // when — THIS conversation's own member gets a fresh snapshot entry.
        harness.snapshotsSubject.send(["abc12345": task(id: "abc12345", resumeCommand: "cd /repo && claude --resume abc12345")])

        // then
        await waitUntil { recomputeCount.value > baseline }
        #expect(recomputeCount.value > baseline)
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
    
    // MARK: - Piece 2/3: no git use-case calls are ever made from the VM any more

    @Test func givenATaskLifecycle_whenObserved_thenNoGitUseCaseMembersAreEverCalled() async {
        // given — `TaskDetailUseCase` no longer declares `gitChanges`/`schedule`/`previewFile` at
        // all, so `MockTaskDetailUseCase` has no such members either; this is a compile-time
        // guarantee as much as a runtime one. This test only pins the VM's own git-free lifecycle:
        // appearing, a listing update, and disappearing complete with no git poll ever scheduled.
        let harness = makeSUT()
        let sut = harness.sut
        let running = task(status: "running")
        harness.detailBox.value = running
        harness.snapshotBox.value = running

        // when
        sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { sut.task != nil }
        sut.didDisappear()

        // then
        #expect(sut.task?.taskID == "abc12345")
    }
}

@MainActor
private final class VMApprovalProbe: CallerApprovalUseCase {
    var pageCount = 0

    private let request = CallerApprovalRequest(raw: [
        "request_id": .string("vm-approval"), "task_id": .string("abc12345"),
        "action_digest": .string(String(repeating: "a", count: 64)), "owner_revision": .number(1),
        "generation": .string("generation-1"), "interaction_owner": .string("monitor"),
        "disposition": .string("pending"), "delivery": .string("pending"),
        "execution_outcome": .string("unknown"), "deadline": .number(Date().addingTimeInterval(600).timeIntervalSince1970),
        "complete": .bool(true), "action": .object(["tool_name": .string("Bash"), "input": .object(["command": .string("echo test")])])
    ])

    func page(taskID: String?, workflowRunID: String?, cursor: String?) async throws -> CallerApprovalPage {
        pageCount += 1
        return CallerApprovalPage(requests: [request], total: 1)
    }

    func detail(_ request: CallerApprovalRequest) async throws -> CallerApprovalRequest { request }
    func respond(_ request: CallerApprovalRequest, decision: String) async throws -> CallerApprovalRequest { request }
    func supportsMonitorResponseForCallerApprovals() async throws -> Bool { true }
}

@MainActor
extension TaskDetailVMTests {
    @Test
    func givenUnoptedTask_whenMounted_thenApprovalReadsDoNotStart() async {
        let harness = makeSUT()
        let approval = VMApprovalProbe()
        harness.callerApprovalBox.value = approval
        harness.sut.didAppear()
        harness.detailBox.value = task(status: "running")
        harness.tasksSubject.send([task(status: "running")])
        _ = await waitUntil(timeout: 0.2) { approval.pageCount > 0 }
        #expect(approval.pageCount == 0)
        harness.sut.didDisappear()
    }

    @Test
    func givenTerminalOptedTask_whenMounted_thenApprovalReadsRunOnce() async {
        let harness = makeSUT()
        let approval = VMApprovalProbe()
        harness.callerApprovalBox.value = approval
        var terminal = task(status: "completed")
        var raw = terminal.raw
        raw["caller_approvals"] = .bool(true)
        terminal = TaskInfo(.object(raw))!
        harness.sut.didAppear()
        harness.detailBox.value = terminal
        harness.tasksSubject.send([terminal])
        await waitUntil { approval.pageCount > 0 }
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(approval.pageCount == 1)
        harness.sut.didDisappear()
    }

    @Test
    func givenMissingDetailThenAvailableWhileMounted_whenRecomputed_thenApprovalPollingRecoversWithoutReappearing() async {
        let harness = makeSUT()
        let approval = VMApprovalProbe()
        harness.callerApprovalBox.value = approval
        harness.sut.didAppear()
        var eligible = task(status: "running").raw
        eligible["caller_approvals"] = .bool(true)
        let eligibleTask = TaskInfo(.object(eligible))!
        harness.detailBox.value = eligibleTask
        harness.tasksSubject.send([eligibleTask])
        await waitUntil { approval.pageCount > 0 }
        let beforeDisappear = approval.pageCount
        harness.sut.didDisappear()
        harness.detailBox.value = nil
        harness.tasksSubject.send([])
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(approval.pageCount == beforeDisappear)
    }
}

/// Lets a standalone VM write to a strict routing mock.
func stubTopBarRouting(_ routing: MockTaskDetailRouting) {
    given(routing).publishTopBar(.any, tag: .any).willReturn()
    given(routing).clearTopBar(tag: .any).willReturn()
    given(routing).activateTopBar(tag: .any).willReturn()
    given(routing).deactivateTopBar(tag: .any).willReturn()
    given(routing).retryTopBarActivation(tag: .any).willReturn()
}
