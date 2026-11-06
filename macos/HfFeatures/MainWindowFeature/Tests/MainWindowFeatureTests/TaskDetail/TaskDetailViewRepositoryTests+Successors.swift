import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Synchronization
import Testing

@MainActor
extension TaskDetailViewRepositoryTests {
    @Test func givenOutsideWindowSuccessor_whenObserved_thenSelectedInventoryAndDetailContainIt() async throws {
        // given
        let list = MockTaskListRepository()
        let tooling = MockToolEnvironmentRepository()
        let client = CtlClient(executable: "/fixture/ctl", environment: [:])
        given(tooling).ctl().willReturn(.success(client))
        let root = try #require(TaskInfo(.object(["task_id": .string("root"), "started_at": .string("2026-01-01T00:00:00Z")])))
        given(list).tasks.willReturn([root])
        given(list).task(.any).willReturn(nil)
        given(list).detail(.any).willReturn(nil)
        given(list).resolve(.any).willReturn(root)
        given(list).successorPage(predecessorTaskID: .any, cursor: .any, runtime: .any).willProduce { @Sendable predecessor, _, _ in
            try Self.successorPage(predecessor, child: predecessor == "root" ? "successor" : nil)
        }
        let sut = TaskDetailViewRepository(taskListRepository: list, toolEnvironmentRepository: tooling)
        _ = await sut.resolveTask("root")
        // when
        let partial = try await sut.observeSuccessors("root")
        // then
        #expect(!partial)
        #expect(sut.conversationMembers(of: "root").map(\.taskID) == ["root", "successor"])
        #expect(sut.detail("successor")?.taskID == "successor")
        #expect(list.tasks.map(\.taskID) == ["root"])
    }

    @Test func givenUnboundedFrontier_whenObserved_thenFourPagesStopCycleAndDisposeClearsInventory() async throws {
        // given
        let list = MockTaskListRepository()
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willReturn(.success(CtlClient(executable: "/fixture/ctl", environment: [:])))
        given(list).tasks.willReturn([])
        given(list).resolve(.any).willReturn(nil)
        given(list).successorPage(predecessorTaskID: .any, cursor: .any, runtime: .any).willProduce { @Sendable predecessor, _, _ in
            try Self.successorPage(predecessor, child: predecessor + "x")
        }
        let sut = TaskDetailViewRepository(taskListRepository: list, toolEnvironmentRepository: tooling)
        _ = await sut.resolveTask("root")
        // when / then
        #expect(try await sut.observeSuccessors("root"))
        verify(list).successorPage(predecessorTaskID: .any, cursor: .any, runtime: .any).called(4)
        sut.stopSuccessorObservation()
        #expect(sut.conversationMembers(of: "rootx").isEmpty)
        await #expect(throws: CancellationError.self) { _ = try await sut.observeSuccessors("root") }
    }

    private nonisolated static func successorPage(_ predecessor: String, child: String?) throws -> TaskSuccessorPage {
        let items: [JSONValue] = child.map { [.object(["task_id": .string($0), "continuation_of_task_id": .string(predecessor),
                                                        "session_id": .string("another-session"), "started_at": .string("2026-01-02T00:00:00Z")])] } ?? []
        return try #require(TaskSuccessorPage(raw: ["successor_scope": .string("recorded_tasks"),
            "predecessor_task_id": .string(predecessor), "items": .array(items), "has_more": .bool(false),
            "bootstrap_pending": .bool(false), "next_cursor": .null,
            "catalog_state": .object(["status": .string("ready"), "source": .string("task_catalog"),
                "pending_records": .number(0), "blocked_records": .number(0)])], predecessorTaskID: predecessor))
    }
}

@MainActor
extension TaskDetailViewRepositoryTests {
    @MainActor private final class SuccessorFixture {
        let list = MockTaskListRepository()
        let tooling = MockToolEnvironmentRepository()
        let state = SuccessorProducerState()
        lazy var sut = TaskDetailViewRepository(taskListRepository: list, toolEnvironmentRepository: tooling)
        init() {
            let selected = state
            given(tooling).ctl().willProduce { @Sendable in .success(selected.client) }
            given(list).tasks.willReturn([])
            given(list).task(.any).willReturn(nil)
            given(list).detail(.any).willReturn(nil)
            given(list).resolve(.any).willReturn(nil)
        }

        func mount() async { _ = await sut.resolveTask("root") }
    }

    @Test(arguments: [false, true])
    func givenDelayedReply_whenRuntimeChangesOrDetailDisposes_thenLateRowsCannotEnterInventory(runtimeChanges: Bool) async throws {
        // given
        let fixture = SuccessorFixture()
        let gate = QualificationCheckGate()
        given(fixture.list).successorPage(predecessorTaskID: .any, cursor: .any, runtime: .any).willProduce { @Sendable predecessor, _, _ in
            try Self.successorPage(predecessor, child: "late")
        }
        let delayed = GatedSuccessorTaskListRepository(base: fixture.list, gate: gate)
        let sut = TaskDetailViewRepository(taskListRepository: delayed, toolEnvironmentRepository: fixture.tooling)
        _ = await sut.resolveTask("root")
        let request = Task { try await sut.observeSuccessors("root") }
        await gate.waitForEntry()
        // when
        if runtimeChanges {
            fixture.state.client = CtlClient(executable: "/fixture/two/ctl", environment: [:])
        } else { sut.stopSuccessorObservation() }
        await gate.open()
        // then
        do { _ = try await request.value; Issue.record("Obsolete reply accepted") } catch {}
        #expect(sut.conversationMembers(of: "late").isEmpty)
    }

    @Test func givenKnownRows_whenNextReadFails_thenRowsRemainAndExplicitRetryCanRecover() async throws {
        // given
        let fixture = SuccessorFixture()
        let state = fixture.state
        given(fixture.list).successorPage(predecessorTaskID: .any, cursor: .any, runtime: .any).willProduce { @Sendable predecessor, _, _ in
            if state.fail { throw ToolError.unreadable(tool: "fixture", exitCode: 1, stderr: "transient") }
            return try Self.successorPage(predecessor, child: predecessor == "root" ? "known" : nil)
        }
        await fixture.mount()
        _ = try await fixture.sut.observeSuccessors("root")
        fixture.state.fail = true
        // when
        do { _ = try await fixture.sut.observeSuccessors("root"); Issue.record("Failure hidden") } catch {}
        // then
        #expect(fixture.sut.detail("known")?.taskID == "known")
        fixture.state.fail = false
        #expect(try await fixture.sut.observeSuccessors("root") == false)
    }

    @Test func givenRepeatedCursor_whenFrontierAdvances_thenReadFailsWithoutDroppingKnownRows() async throws {
        // given
        let fixture = SuccessorFixture()
        given(fixture.list).successorPage(predecessorTaskID: .any, cursor: .any, runtime: .any).willProduce { @Sendable predecessor, _, _ in
            try Self.successorRows(predecessor, children: ["known"], headers: 0, cursor: "repeat")
        }
        await fixture.mount()
        // when / then
        await #expect(throws: ToolError.self) { _ = try await fixture.sut.observeSuccessors("root") }
        #expect(fixture.sut.detail("known")?.taskID == "known")
        verify(fixture.list).successorPage(predecessorTaskID: .any, cursor: .any, runtime: .any).called(2)
    }

    @Test func givenCombinedRelatedHeaderBudget_whenObserved_thenOnlyFourHundredRowsAreMerged() async throws {
        // given
        let fixture = SuccessorFixture()
        let state = fixture.state
        given(fixture.list).successorPage(predecessorTaskID: .any, cursor: .any, runtime: .any).willProduce { @Sendable predecessor, _, _ in
            let call = state.nextCall()
            return try Self.successorRows(predecessor, children: (0 ..< 100).map { "child-\(call)-\($0)" },
                                          headers: 100, cursor: "page-\(call)")
        }
        await fixture.mount()
        // when
        #expect(try await fixture.sut.observeSuccessors("root"))
        // then
        #expect(fixture.state.calls == 2)
        #expect(fixture.sut.detail("child-2-99") != nil)
        #expect(fixture.sut.detail("child-3-0") == nil)
    }

    @Test func givenMoreThanThirtyTwoBranches_whenLaterCyclesDrainRetainedFrontier_thenOmittedBranchesRemainPartial() async throws {
        // given
        let fixture = SuccessorFixture()
        let state = fixture.state
        given(fixture.list).successorPage(predecessorTaskID: .any, cursor: .any, runtime: .any).willProduce { @Sendable predecessor, _, _ in
            _ = state.nextCall()
            return try Self.successorRows(predecessor, children: predecessor == "root" ? (0 ..< 40).map { "branch-\($0)" } : [], headers: 0)
        }
        await fixture.mount()
        // when / then
        for _ in 0 ..< 8 { #expect(try await fixture.sut.observeSuccessors("root")) }
        #expect(fixture.state.calls == 32)
        // A new full query from root still sees the omitted branches, so remains partial.
        #expect(try await fixture.sut.observeSuccessors("root"))
    }

    @Test func givenListingPulses_whenDetailOnlyRecomputes_thenNoSuccessorOperationIsLaunched() async {
        // given
        let fixture = SuccessorFixture()
        await fixture.mount()
        // when
        for _ in 0 ..< 20 { _ = fixture.sut.conversationMembers(of: "root") }
        // then
        verify(fixture.list).successorPage(predecessorTaskID: .any, cursor: .any, runtime: .any).called(0)
    }

    @Test func givenAcknowledgedContinue_whenDiscoveryIsDelayed_thenAckReturnsAndCapturedMutationTargetNeverChanges() async throws {
        // given
        let fixture = SuccessorFixture()
        let actions = MockTaskActionRepository()
        let gate = QualificationCheckGate()
        given(actions).resume(.any, text: .any, onResumed: .any).willReturn("acknowledged")
        given(fixture.list).successorPage(predecessorTaskID: .any, cursor: .any, runtime: .any).willProduce { @Sendable predecessor, _, _ in
            try Self.successorPage(predecessor, child: "late")
        }
        let delayed = GatedSuccessorTaskListRepository(base: fixture.list, gate: gate)
        let sut = TaskDetailViewRepository(taskListRepository: delayed, taskActionRepository: actions, toolEnvironmentRepository: fixture.tooling)
        _ = await sut.resolveTask("captured")
        // when: this must return before opening the discovery gate.
        #expect(try await sut.resume("captured", text: "continue", onResumed: { _ in }) == "acknowledged")
        await gate.waitForEntry()
        sut.stopSuccessorObservation()
        await gate.open()
        // then
        verify(actions).resume(.value("captured"), text: .value("continue"), onResumed: .any).called(1)
        verify(actions).resume(.value("late"), text: .any, onResumed: .any).called(0)
        #expect(sut.conversationMembers(of: "late").isEmpty)
    }

    @Test(arguments: ["bootstrap", "blocked", "history", "authority", "unknown"])
    func givenIncompleteRootWithCursor_whenHealthyContinuationCompletes_thenPriorHealthRemainsPartial(health: String) async throws {
        // given
        let fixture = SuccessorFixture()
        given(fixture.list).successorPage(predecessorTaskID: .any, cursor: .any, runtime: .any).willProduce { @Sendable predecessor, cursor, _ in
            var raw: [String: JSONValue] = ["successor_scope": .string("recorded_tasks"), "predecessor_task_id": .string(predecessor),
                "items": .array([]), "has_more": .bool(cursor == nil), "bootstrap_pending": .bool(cursor == nil && health == "bootstrap"),
                "next_cursor": cursor == nil ? .string("continuation") : .null,
                "catalog_state": .object(["status": .string(cursor == nil && health == "blocked" ? "blocked" : "ready"),
                    "source": .string("task_catalog"), "pending_records": .number(0), "blocked_records": .number(0)])]
            if cursor == nil {
                raw["history_incomplete"] = .bool(health == "history")
                raw["authority_incomplete"] = .bool(health == "authority")
                if health == "unknown" { raw.removeValue(forKey: "catalog_state") }
            }
            return try #require(TaskSuccessorPage(raw: raw, predecessorTaskID: predecessor))
        }
        await fixture.mount()
        // when / then: bootstrap/blocked stop the first cycle; other flags may continue serially.
        #expect(try await fixture.sut.observeSuccessors("root"))
        if health == "bootstrap" || health == "blocked" {
            #expect(try await fixture.sut.observeSuccessors("root"))
        }
        #expect(fixture.sut.successorObservationError != nil)
    }

    @Test func givenFreshHealthyRootRefresh_whenRecordedRowsDisappear_thenOnlySuccessorInventoryIsReconciled() async throws {
        // given
        let fixture = SuccessorFixture()
        let refresh = SuccessorProducerState()
        given(fixture.list).successorPage(predecessorTaskID: .any, cursor: .any, runtime: .any).willProduce { @Sendable predecessor, _, _ in
            if refresh.partial {
                return try #require(TaskSuccessorPage(raw: ["successor_scope": .string("recorded_tasks"),
                    "predecessor_task_id": .string(predecessor), "items": .array([]), "has_more": .bool(false),
                    "bootstrap_pending": .bool(false), "history_incomplete": .bool(true), "next_cursor": .null,
                    "catalog_state": .object(["status": .string("ready"), "source": .string("task_catalog"),
                        "pending_records": .number(0), "blocked_records": .number(0)])], predecessorTaskID: predecessor))
            }
            return try Self.successorPage(predecessor, child: refresh.found && predecessor == "root" ? "old-successor" : nil)
        }
        let sessionPage = try #require(TaskHistoryPage(raw: ["items": .array([.object(["task_id": .string("session-related")])]),
            "has_more": .bool(false), "bootstrap_pending": .bool(false), "next_cursor": .null]))
        given(fixture.list).conversationPage(sessionID: .any, cursor: .any, limit: .any).willReturn(sessionPage)
        await fixture.mount()
        _ = try await fixture.sut.conversationHistory(sessionID: "session", cursor: nil)
        _ = try await fixture.sut.observeSuccessors("root")
        #expect(fixture.sut.detail("old-successor") != nil)
        refresh.found = false
        refresh.partial = true
        #expect(try await fixture.sut.observeSuccessors("root"))
        #expect(fixture.sut.detail("old-successor") != nil)
        refresh.partial = false
        // when
        #expect(try await fixture.sut.observeSuccessors("root") == false)
        // then: this concerns recorded observation only, without pending-launch inference.
        #expect(fixture.sut.detail("old-successor") == nil)
        #expect(fixture.sut.task("old-successor") == nil)
        #expect(fixture.sut.task("session-related") != nil)
    }

    @Test func givenOutsideWindowSuccessor_whenScopedPublisherChanges_thenActualCurrentTaskPresentationAdvances() async throws {
        // given
        let fixture = SuccessorFixture()
        let root = try #require(TaskInfo(.object(["task_id": .string("root"), "status": .string("completed"),
            "started_at": .string("2026-01-01T00:00:00Z")])))
        let successor = try #require(Self.successorPage("root", child: "successor").history.items.first)
        let harness = TaskDetailVMTests().makeConversationSUT(openedAs: "root", initialMembers: [root], stubbedMembers: [root, successor])
        given(fixture.list).successorPage(predecessorTaskID: .any, cursor: .any, runtime: .any).willProduce { @Sendable predecessor, _, _ in
            try Self.successorPage(predecessor, child: predecessor == "root" ? "successor" : nil)
        }
        given(fixture.list).tasksPublisher().willReturn(Just([root]).eraseToAnyPublisher())
        await fixture.mount()
        harness.sut.didAppear()
        await waitUntil { !harness.sut.conversationLoading }
        var changedSnapshots: [[TaskInfo]] = []
        let subscription = fixture.sut.tasksPublisher().removeDuplicates().sink { snapshot in
            changedSnapshots.append(snapshot)
            // Actual repository detail values drive presentation; a missing fallback drops the row.
            harness.membersBox.value = [root] + fixture.sut.conversationMembers(of: "successor").compactMap { fixture.sut.detail($0.taskID) }
            harness.tasksSubject.send(snapshot)
        }
        // when
        _ = try await fixture.sut.observeSuccessors("root")
        await waitUntil { harness.sut.task?.taskID == "successor" }
        // then
        #expect(harness.sut.currentTaskID == "successor")
        #expect(harness.sut.task?.sessionID == "another-session")
        #expect(changedSnapshots.contains { $0.contains { $0.taskID == "successor" } })
        harness.sut.didDisappear()
        subscription.cancel()
    }

    private nonisolated static func successorRows(_ predecessor: String, children: [String], headers: Int, cursor: String? = nil) throws -> TaskSuccessorPage {
        let items = children.map { JSONValue.object(["task_id": .string($0), "continuation_of_task_id": .string(predecessor)]) }
        let related = (0 ..< headers).map { JSONValue.object(["task_id": .string("header-\(cursor ?? "none")-\($0)")]) }
        return try #require(TaskSuccessorPage(raw: ["successor_scope": .string("recorded_tasks"), "predecessor_task_id": .string(predecessor),
            "items": .array(items), "related_headers": .array(related), "has_more": .bool(cursor != nil),
            "bootstrap_pending": .bool(false), "next_cursor": cursor.map(JSONValue.string) ?? .null,
            "catalog_state": .object(["status": .string("ready"), "source": .string("task_catalog"),
                "pending_records": .number(0), "blocked_records": .number(0)])], predecessorTaskID: predecessor))
    }
}

@MainActor
extension TaskDetailVMTests {
    @Test func givenMountedDetail_whenRepeatedListingTicksArrive_thenSuccessorReadsDoNotFollowPollingCadence() async {
        // given
        let root = conversationTask("root", status: "completed", minute: 0)
        let harness = makeConversationSUT(openedAs: "root", initialMembers: [root])
        harness.sut.didAppear()
        await waitUntil { !harness.sut.conversationLoading }
        // when
        for _ in 0 ..< 20 { harness.tasksSubject.send([root]) }
        await waitUntil { harness.sut.task?.taskID == "root" }
        // then
        verify(harness.useCase).observeSuccessors(.value("root")).called(1)
        harness.sut.didDisappear()
    }
}

/// Suspends the async boundary without asking Mockable's synchronous producer to await.
private final class GatedSuccessorTaskListRepository: TaskListRepository {
    let base: MockTaskListRepository
    let gate: QualificationCheckGate

    init(base: MockTaskListRepository, gate: QualificationCheckGate) {
        self.base = base
        self.gate = gate
    }

    func successorPage(predecessorTaskID: String, cursor: String?, runtime: QualificationRuntimeToken) async throws -> TaskSuccessorPage {
        let captured: Result<TaskSuccessorPage, Error>
        do {
            captured = .success(try await base.successorPage(predecessorTaskID: predecessorTaskID, cursor: cursor, runtime: runtime))
        } catch { captured = .failure(error) }
        await gate.wait()
        return try captured.get()
    }

    var historyState: HistoryLoadingState { base.historyState }
    func historyStatePublisher() -> AnyPublisher<HistoryLoadingState, Never> { base.historyStatePublisher() }
    func loadMoreHistory() async { await base.loadMoreHistory() }
    func resolve(_ id: String) async -> TaskInfo? { await base.resolve(id) }
    func conversationPage(sessionID: String, cursor: String?, limit: Int) async throws -> TaskHistoryPage {
        try await base.conversationPage(sessionID: sessionID, cursor: cursor, limit: limit)
    }

    var tasks: [TaskInfo] { base.tasks }
    var listError: ToolError? { base.listError }
    var hasListed: Bool { base.hasListed }
    var titles: [String: String] { base.titles }
    func tasksPublisher() -> AnyPublisher<[TaskInfo], Never> { base.tasksPublisher() }
    func listErrorPublisher() -> AnyPublisher<ToolError?, Never> { base.listErrorPublisher() }
    func hasListedPublisher() -> AnyPublisher<Bool, Never> { base.hasListedPublisher() }
    func titlesPublisher() -> AnyPublisher<[String: String], Never> { base.titlesPublisher() }
    func countsPublisher() -> AnyPublisher<TaskListCounts, Never> { base.countsPublisher() }
    func start() { base.start() }
    func refresh() async { await base.refresh() }
    func refreshAndWait() async -> Result<Void, ToolError> { await base.refreshAndWait() }
    func settingsChanged() { base.settingsChanged() }
    func runtimeBecameReady() { base.runtimeBecameReady() }
    func title(_ taskID: String) -> String { base.title(taskID) }
    func task(_ id: String) -> TaskInfo? { base.task(id) }
    func detail(_ id: String) -> TaskInfo? { base.detail(id) }
    func runningInSubtrees(of ids: [String]) -> [String] { base.runningInSubtrees(of: ids) }
    var runningCount: Int { base.runningCount }
    var connectionLine: String { base.connectionLine }
}

/// Mutable callback inputs use real synchronization because Mockable invokes them off MainActor.
private final class SuccessorProducerState: Sendable {
    private struct Values: Sendable {
        var client = CtlClient(executable: "/fixture/one/ctl", environment: [:])
        var fail = false
        var calls = 0
        var found = true
        var partial = false
    }

    private let values = Mutex(Values())

    var client: CtlClient {
        get { values.withLock { $0.client } }
        set { values.withLock { $0.client = newValue } }
    }

    var fail: Bool {
        get { values.withLock { $0.fail } }
        set { values.withLock { $0.fail = newValue } }
    }

    var calls: Int { values.withLock { $0.calls } }
    var found: Bool {
        get { values.withLock { $0.found } }
        set { values.withLock { $0.found = newValue } }
    }

    var partial: Bool {
        get { values.withLock { $0.partial } }
        set { values.withLock { $0.partial = newValue } }
    }

    func nextCall() -> Int {
        values.withLock { $0.calls += 1; return $0.calls }
    }
}
