import Combine
import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
import PbTestUtilities
import Testing

struct TaskHistoryPaginationTests {
    private func response(_ ids: [String], cursor: String? = nil, status: String = "completed", activeCount: Int = 0, pending: Bool = false) -> ProcessOutput {
        let raw: [String: JSONValue] = ["v": .number(5), "result": .object([
            "items": .array(ids.map { .object(["task_id": .string($0), "status": .string(status), "title": .string($0)]) }),
            "next_cursor": cursor.map(JSONValue.string) ?? .null, "has_more": .bool(cursor != nil),
            "bootstrap_pending": .bool(pending), "total_active_count": .number(Double(activeCount))
        ])]
        return stdout(JSONValue.object(raw).rendered())
    }

    @Test func givenThousandCatalogRecords_whenLoadingMoreAndPolling_thenOnlyOneExplicitPageIsAddedAndOldPagesRemain() async {
        // given: the test transport exposes only requested pages, never the full catalog.
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let catalog = (0 ..< 1000).map { "task-\($0)" }
        let runner = StubProcessRunner { call in
            if call.arguments.contains("--active-only") { return .success(response([])) }
            if call.arguments.contains("--cursor=page2") { return .success(response(Array(catalog[100 ..< 200]), cursor: "page3")) }
            if let ids = call.arguments.first(where: { $0.hasPrefix("--task-ids=") }) {
                return .success(response(ids.dropFirst("--task-ids=".count).split(separator: ",").map(String.init)))
            }
            return .success(response(Array(catalog.prefix(100)), cursor: "page2"))
        }
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = TaskListRepositoryImplTests().makeSUT(toolEnvironment: environment)
        // when
        await sut.refresh()
        #expect(sut.tasks.count == 100)
        await sut.loadMoreHistory()
        #expect(sut.tasks.count == 200)
        await sut.refresh()
        // then
        #expect(sut.tasks.count == 200)
        #expect(sut.historyState.nextCursor == "page3")
        #expect(runner.calls.filter { $0.arguments.contains(where: { $0.hasPrefix("--cursor=") }) }.count == 1)
        #expect(runner.calls.allSatisfy { $0.arguments.contains("--limit=100") })
        #expect(sut.titleLoadPassCount == 0)
    }

    @Test func givenMoreThan100ActiveWithOlderLoadedMember_whenItFinishes_thenBoundedOrdinaryPollRefreshesIt() async {
        // given
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let finished = LockedBox(false)
        let runner = StubProcessRunner { call in
            if let ids = call.arguments.first(where: { $0.hasPrefix("--task-ids=") }) {
                let requested = String(ids.dropFirst("--task-ids=".count)).split(separator: ",").map(String.init)
                return .success(response(requested, status: finished.value ? "completed" : "running", activeCount: 150))
            }
            if call.arguments.contains("--cursor=older") {
                return .success(response((100 ..< 150).map { "active-\($0)" }, status: "running", activeCount: 150))
            }
            return .success(response((0 ..< 100).map { "active-\($0)" }, cursor: "older", status: "running", activeCount: 150))
        }
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = TaskListRepositoryImplTests().makeSUT(toolEnvironment: environment)
        await sut.refresh()
        await sut.loadMoreHistory()
        #expect(sut.runningCount == 150)
        // when
        finished.mutate { $0 = true }
        await sut.refresh()
        // then
        #expect(sut.task("active-120")?.status == .completed)
        let batches = runner.calls.compactMap { $0.arguments.first(where: { $0.hasPrefix("--task-ids=") }) }
        #expect(batches.count == 1)
        #expect(batches.allSatisfy { $0.split(separator: ",").count <= 100 })
    }

    @Test func givenActiveInventoryFailure_whenPolling_thenLoadedRowsAndErrorRemain() async {
        // given
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let fail = LockedBox(false)
        let runner = StubProcessRunner { call in
            if fail.value, call.arguments.contains("--active-only") {
                return .failure(.unreadable(tool: "polybridge-ctl", exitCode: 1, stderr: "active inventory unavailable"))
            }
            return .success(response(["loaded"], status: "running", activeCount: 150))
        }
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = TaskListRepositoryImplTests().makeSUT(toolEnvironment: environment)
        await sut.refresh()
        // when
        fail.mutate { $0 = true }
        await sut.refresh()
        // then
        #expect(sut.task("loaded") != nil)
        #expect(sut.listError != nil)
        #expect(sut.historyState.error != nil)
        #expect(sut.runningCount == 150)
        // when the explicit Retry action succeeds, it refreshes active inventory, not an older page.
        fail.mutate { $0 = false }
        await sut.loadMoreHistory()
        #expect(sut.listError == nil)
        #expect(sut.historyState.error == nil)
    }

    @Test func givenConcurrentPollAndLoadMore_whenOlderPageFinishesFirst_thenItsCursorAndRowsSurvivePoll() async {
        // given
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let blockPoll = LockedBox(false)
        let entered = LockedBox(false)
        let gate = AsyncGate()
        let runner = StubProcessRunner { call in
            if call.arguments.contains("--active-only") { return .success(response([])) }
            if call.arguments.contains("--cursor=page2") { return .success(response(["older"], cursor: "page3")) }
            if call.arguments.contains("--task-ids=older") { return .success(response(["older"])) }
            if blockPoll.value { entered.mutate { $0 = true }; gate.waitSync() }
            return .success(response(["newest"], cursor: "page2"))
        }
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = TaskListRepositoryImplTests().makeSUT(toolEnvironment: environment)
        await sut.refresh()
        blockPoll.mutate { $0 = true }
        let poll = Task { await sut.refresh() }
        await waitUntil { entered.value }
        // when
        await sut.loadMoreHistory()
        gate.open()
        await poll.value
        // then
        #expect(Set(sut.tasks.map(\.taskID)) == ["newest", "older"])
        #expect(sut.historyState.nextCursor == "page3")
    }

    @Test func givenChildOnlyHistoryPage_whenAncestorIsRelatedHeader_thenInitialInventoryRetainsTreeMetadata() async {
        // given
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let runner = StubProcessRunner { call in
            if call.arguments.contains("--active-only") { return .success(response([])) }
            let result: [String: JSONValue] = ["items": .array([.object(["task_id": .string("child"),
                "parent_task_id": .string("parent"), "root_task_id": .string("parent"), "depth": .number(1)])]),
                "related_headers": .array([.object(["task_id": .string("parent"), "status": .string("completed")])]),
                "next_cursor": .string("older"), "has_more": .bool(true), "bootstrap_pending": .bool(false)]
            return .success(stdout(JSONValue.object(["v": .number(5), "result": .object(result)]).rendered()))
        }
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = TaskListRepositoryImplTests().makeSUT(toolEnvironment: environment)
        // when
        await sut.refresh()
        // then
        #expect(Set(sut.tasks.map(\.taskID)) == ["child", "parent"])
        #expect(sut.task("child")?.parentTaskID == "parent")
        #expect(sut.historyState.nextCursor == "older")
    }

    @Test func givenPartialBootstrapInventories_whenStatusesChange_thenCountsAndFinishNotificationsWaitForCompleteIndex() async {
        // given
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let state = LockedBox((pending: true, status: "running", count: 2))
        let runner = StubProcessRunner { _ in
            let current = state.value
            return .success(response(["root"], status: current.status, activeCount: current.count, pending: current.pending))
        }
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let notifier = MockFinishNotifier()
        let sut = TaskListRepositoryImplTests().makeSUT(toolEnvironment: environment, finishNotifier: notifier)
        // when / then: partial bootstrap cannot establish a count or notification baseline.
        await sut.refresh()
        #expect(!sut.historyState.countsComplete)
        #expect(sut.runningCount == 0)
        state.mutate { $0 = (false, "running", 300) }
        await sut.refresh()
        #expect(sut.historyState.countsComplete)
        #expect(sut.runningCount == 300)
        state.mutate { $0 = (true, "completed", 1) }
        await sut.refresh()
        #expect(!sut.historyState.countsComplete)
        #expect(sut.runningCount == 300)
        verify(notifier).notify(.any, titleFor: .any).called(0)
        // when a complete inventory returns, the real transition is reported once.
        state.mutate { $0 = (false, "completed", 299) }
        await sut.refresh()
        // then
        verify(notifier).notify(.any, titleFor: .any).called(1)
        #expect(sut.runningCount == 299)
    }

    @Test func givenUncertainTerminalHeader_whenPolling_thenNoFinishNotificationUntilOutcomeReconciles() async {
        // given
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let phase = LockedBox(0)
        let runner = StubProcessRunner { _ in
            let current = phase.value
            let item: [String: JSONValue] = ["task_id": .string("root"), "status": .string(current == 0 ? "running" : current == 3 ? "completed" : "failed"),
                "needs_reconciliation": .bool(current == 1 || current == 2), "status_reconciled": .bool(current == 3),
                "process_identity_state": .string(current >= 2 ? "dead" : "uncertain")]
            let result: [String: JSONValue] = ["items": .array([.object(item)]), "next_cursor": .null,
                "has_more": .bool(false), "bootstrap_pending": .bool(false), "total_active_count": .null, "counts_complete": .bool(false)]
            return .success(stdout(JSONValue.object(["v": .number(5), "result": .object(result)]).rendered()))
        }
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let notifier = MockFinishNotifier()
        let finished = LockedBox<[TaskInfo]>([])
        let sut = TaskListRepositoryImplTests().makeSUT(toolEnvironment: environment, finishNotifier: notifier)
        given(notifier).notify(.any, titleFor: .any).willProduce { tasks, _ in finished.mutate { $0.append(contentsOf: tasks) } }
        await sut.refresh()
        // when
        phase.mutate { $0 = 1 }
        await sut.refresh()
        // then
        #expect(finished.value.isEmpty)
        phase.mutate { $0 = 2 }
        await sut.refresh()
        #expect(finished.value.isEmpty, "verified death alone does not establish the agent outcome")
        phase.mutate { $0 = 3 }
        await sut.refresh()
        #expect(finished.value.map(\.taskID) == ["root"])
    }

    @Test func givenOlderLoadedTerminalMarkedForReconciliation_whenPolling_thenExactIDBatchContinuesUpdatingIt() async {
        // given
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let runner = StubProcessRunner { call in
            if call.arguments.contains("--active-only") { return .success(response([])) }
            if call.arguments.contains("--task-ids=older") { return .success(response(["older"], status: "completed")) }
            if call.arguments.contains("--cursor=older-page") {
                let result: [String: JSONValue] = ["items": .array([.object(["task_id": .string("older"), "status": .string("failed"),
                    "needs_reconciliation": .bool(true), "process_identity_state": .string("uncertain")])]),
                    "next_cursor": .null, "has_more": .bool(false), "bootstrap_pending": .bool(false)]
                return .success(stdout(JSONValue.object(["v": .number(5), "result": .object(result)]).rendered()))
            }
            return .success(response(["newest"], cursor: "older-page"))
        }
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = TaskListRepositoryImplTests().makeSUT(toolEnvironment: environment)
        await sut.refresh()
        await sut.loadMoreHistory()
        // when
        await sut.refresh()
        // then
        #expect(sut.task("older")?.status == .completed)
        #expect(runner.calls.filter { $0.arguments.contains("--task-ids=older") }.count == 1)
    }

    @Test func givenLoadedHistory_whenAuthorityPrepares_thenRowsCursorAndCountsSurviveUntilRecovery() async {
        // given
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let preparing = LockedBox(false)
        let runner = StubProcessRunner { call in
            if preparing.value {
                let result: [String: JSONValue] = ["items": .array([]), "next_cursor": .null,
                    "has_more": .bool(false), "bootstrap_pending": .bool(true), "counts_complete": .bool(false),
                    "catalog_state": .object(["status": .string("preparing"), "source": .string("task"), "pending_records": .number(150)])]
                return .success(stdout(JSONValue.object(["v": .number(5), "result": .object(result)]).rendered()))
            }
            if call.arguments.contains("--active-only") { return .success(response([], activeCount: 4)) }
            if call.arguments.contains("--cursor=page2") { return .success(response(["older"], cursor: "page3")) }
            if let ids = call.arguments.first(where: { $0.hasPrefix("--task-ids=") }) {
                return .success(response(ids.dropFirst("--task-ids=".count).split(separator: ",").map(String.init)))
            }
            return .success(response(["newest"], cursor: "page2"))
        }
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = TaskListRepositoryImplTests().makeSUT(toolEnvironment: environment)
        await sut.refresh()
        await sut.loadMoreHistory()
        // when
        preparing.mutate { $0 = true }
        await sut.refresh()
        // then
        #expect(Set(sut.tasks.map(\.taskID)) == ["newest", "older"])
        #expect(sut.historyState.nextCursor == "page3")
        #expect(sut.historyState.hasMore)
        #expect(sut.historyState.catalogState.status == .preparing)
        #expect(!sut.historyState.countsComplete)
        #expect(sut.runningCount == 4)
        #expect(sut.listError == nil)
        // when / then
        preparing.mutate { $0 = false }
        await sut.refresh()
        #expect(sut.historyState.catalogState.isReady)
        #expect(sut.historyState.nextCursor == "page3")
    }

    @Test func givenColdPreparation_whenTwoSecondRetryFires_thenAuthoritativeBaselineLoadsAutomatically() async {
        // given
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let preparing = LockedBox(true)
        let runner = StubProcessRunner { _ in .success(response(preparing.value ? [] : ["historical"], pending: preparing.value)) }
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let scheduler = MockScheduling()
        let retry = LockedBox<(@Sendable () -> Void)?>(nil)
        given(scheduler).now().willReturn(Date())
        given(scheduler).schedule(after: .value(2), execute: .any).willProduce { _, work in
            retry.mutate { $0 = work }
            return AnyCancellable {}
        }
        let sut = TaskListRepositoryImplTests().makeSUT(toolEnvironment: environment, scheduler: scheduler)
        // when
        await sut.refresh()
        // then
        #expect(!sut.hasListed)
        #expect(retry.value != nil)
        #expect(sut.listError == nil)
        // when
        preparing.mutate { $0 = false }
        retry.value?()
        await waitUntil { sut.hasListed }
        // then
        #expect(sut.tasks.map(\.taskID) == ["historical"])
        #expect(!sut.historyState.bootstrapPending)
        verify(scheduler).schedule(after: .value(2), execute: .any).called(1)
    }

}
