import Combine
import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
import PbTestUtilities
import Testing

struct TaskCatalogBlockedTests {
    @Test func givenColdBlockedCatalog_whenPresentedAndRetried_thenRowsAndRecoveryAreAvailableWithoutAuthorityBaseline() async {
        // given
        let phase = LockedBox("blocked")
        let runner = StubProcessRunner { _ in .success(response(phase.value, taskStatus: phase.value == "blocked" ? "running" : "completed")) }
        let environment = environment(runner)
        let scheduler = MockScheduling()
        given(scheduler).now().willReturn(Date())
        given(scheduler).schedule(after: .any, execute: .any).willReturn(AnyCancellable {})
        let notifier = MockFinishNotifier()
        let sut = TaskListRepositoryImplTests().makeSUT(toolEnvironment: environment, finishNotifier: notifier, scheduler: scheduler)
        // when
        await sut.refresh()
        // then: durable blockers finish presentation, not discovery or notification readiness.
        #expect(sut.hasListed)
        #expect(sut.tasks.map(\.taskID) == ["root"])
        #expect(sut.historyState.catalogState.status == .blocked)
        #expect(sut.historyState.catalogState.reason == "Oversized metadata: inspect root directly")
        #expect(sut.historyState.historyIncomplete)
        #expect(!sut.historyState.countsComplete)
        #expect(sut.listError == nil)
        verify(scheduler).schedule(after: .value(2), execute: .any).called(0)
        verify(notifier).notify(.any, titleFor: .any).called(0)
        // when: the Retry action must refresh the catalog even without a pagination cursor.
        phase.mutate { $0 = "ready" }
        await sut.loadMoreHistory()
        // then: the first authoritative history establishes the baseline without historical alerts.
        #expect(sut.historyState.catalogState.isReady)
        #expect(sut.historyState.countsComplete)
        #expect(sut.task("root")?.status == .completed)
        #expect(runner.calls.filter { $0.arguments.contains("--active-only") }.count == 1)
        verify(notifier).notify(.any, titleFor: .any).called(0)
    }

    @Test func givenLoadedHistory_whenCatalogBlocksAndRecovers_thenRowsCursorAndNotificationBaselineSurvive() async {
        // given
        let phase = LockedBox("ready")
        let runner = StubProcessRunner { _ in .success(response(phase.value, taskStatus: phase.value == "ready" ? "running" : "completed", cursor: "older")) }
        let notifier = MockFinishNotifier()
        let sut = TaskListRepositoryImplTests().makeSUT(toolEnvironment: environment(runner), finishNotifier: notifier)
        await sut.refresh()
        // when
        phase.mutate { $0 = "blocked" }
        await sut.refresh()
        // then
        #expect(sut.hasListed)
        #expect(sut.tasks.map(\.taskID) == ["root"])
        #expect(sut.historyState.nextCursor == "older")
        #expect(sut.historyState.hasMore)
        #expect(!sut.historyState.countsComplete)
        verify(notifier).notify(.any, titleFor: .any).called(0)
        // when
        phase.mutate { $0 = "recovered" }
        await sut.loadMoreHistory()
        // then: a genuine transition after an established baseline is reported once.
        #expect(sut.historyState.catalogState.isReady)
        #expect(sut.historyState.nextCursor == "older")
        verify(notifier).notify(.matching { $0.map(\.taskID) == ["root"] }, titleFor: .any).called(1)
        #expect(!runner.calls.contains { $0.arguments.contains("--cursor=older") })
    }

    @Test func givenBlockedCatalogWithDeferredWork_whenOnlyPersistentBlockRemains_thenPreparationRetryCancels() async {
        // given
        let pending = LockedBox(true)
        let runner = StubProcessRunner { _ in .success(response("blocked", taskStatus: "completed", pending: pending.value)) }
        let scheduler = MockScheduling()
        let retry = LockedBox<(@Sendable () -> Void)?>(nil)
        let cancelled = LockedBox(0)
        given(scheduler).now().willReturn(Date())
        given(scheduler).schedule(after: .value(2), execute: .any).willProduce { _, action in
            retry.mutate { $0 = action }
            return AnyCancellable { cancelled.mutate { $0 += 1 } }
        }
        let sut = TaskListRepositoryImplTests().makeSUT(toolEnvironment: environment(runner), scheduler: scheduler)
        // when
        await sut.refresh()
        // then: persistent diagnostics are visible while temporary work can still progress.
        #expect(sut.hasListed)
        #expect(sut.historyState.catalogState.status == .blocked)
        #expect(sut.historyState.bootstrapPending)
        #expect(retry.value != nil)
        #expect(cancelled.value == 0)
        // when
        pending.mutate { $0 = false }
        await sut.refresh()
        // then: a pure persistent blocker waits for a scoped repair and explicit read retry.
        #expect(!sut.historyState.bootstrapPending)
        #expect(cancelled.value == 1)
        verify(scheduler).schedule(after: .value(2), execute: .any).called(1)
    }

    private func environment(_ runner: StubProcessRunner) -> MockToolEnvironmentRepository {
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        return environment
    }

    private func response(_ phase: String, taskStatus: String, cursor: String? = nil, pending: Bool = false) -> ProcessOutput {
        let blocked = phase == "blocked"
        let raw: [String: JSONValue] = ["v": .number(5), "result": .object([
            "items": .array([.object(["task_id": .string("root"), "status": .string(taskStatus), "title": .string("Root")])]),
            "next_cursor": blocked ? .null : cursor.map(JSONValue.string) ?? .null,
            "has_more": .bool(!blocked && cursor != nil), "bootstrap_pending": .bool(pending),
            "history_incomplete": .bool(blocked), "counts_complete": .bool(!blocked), "total_active_count": .number(blocked ? 0 : 1),
            "catalog_state": .object(["status": .string(blocked ? "blocked" : "ready"), "source": .string("task_catalog"),
                "reason": blocked ? .string("Oversized metadata: inspect root directly") : .null])
        ])]
        return stdout(JSONValue.object(raw).rendered())
    }
}
