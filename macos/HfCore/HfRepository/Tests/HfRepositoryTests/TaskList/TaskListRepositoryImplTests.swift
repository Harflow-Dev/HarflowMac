import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
import Testing

@Suite struct TaskListRepositoryImplTests {

    func historyStdout(_ json: String) -> ProcessOutput {
        var raw = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        raw["product"] = raw["product"] ?? "harflow"
        raw["format"] = raw["format"] ?? "harflow.ctl"
        raw["v"] = 1
        raw["product_version"] = raw["product_version"] ?? "0.0.1"
        if let items = raw.removeValue(forKey: "tasks") {
            raw["result"] = ["items": items, "next_cursor": NSNull(), "has_more": false, "bootstrap_pending": false]
        }
        let data = (try? JSONSerialization.data(withJSONObject: raw)) ?? Data()
        return stdout(String(bytes: data, encoding: .utf8) ?? "")
    }

    // MARK: Fixtures

    func ctlClient(listing: [String], runner: StubProcessRunner? = nil) -> CtlClient {
        let payload = "[" + listing.map {
            #"{"task_id":"\#($0)","status":"running","backend":"claude"}"#
        }
.joined(separator: ",") + "]"
        let stub = runner ?? StubProcessRunner(output: historyStdout(#"{"v":2,"tasks":\#(payload)}"#))
        return CtlClient(executable: "/bin/echo", environment: [:], runner: PositiveCtlRunner(stub))
    }

    /// A `MockScheduling` pre-stubbed with harmless defaults for every member, used as `makeSUT`'s
    /// default `scheduler:` argument. Evaluated fresh per call (it is a default *parameter*
    /// expression, not a shared value), so each test gets its own instance.
    ///
    /// **Why this lives in a default-argument factory and not inside `makeSUT`'s body:** `Mockable`'s
    /// `given` queue only rotates past a stub once a *later* one has been registered for the same
    /// member (see the note on the `Mockable` FIFO pitfall in `TaskSnapshotRepositoryImplTests`). If
    /// `makeSUT` unconditionally re-stubbed `scheduler` after a caller had already configured it
    /// (e.g. to capture a closure with `.willProduce`), the caller's stub and `makeSUT`'s would both
    /// be registered, and the *caller's* carefully-built stub could end up shadowed. Stubbing only
    /// inside the default-argument expression means it never runs at all when a caller supplies its
    /// own `scheduler`.
    private static func defaultScheduler() -> MockScheduling {
        let scheduler = MockScheduling()
        given(scheduler).now().willReturn(Date())
        given(scheduler).schedule(after: .any, execute: .any).willReturn(AnyCancellable {})
        given(scheduler).scheduleRepeating(every: .any, execute: .any).willReturn(AnyCancellable {})
        return scheduler
    }

    /// A `MockMonitorVisibility` pre-stubbed visible, so the safety poll's gating reads "someone
    /// is looking" and every pre-visibility test keeps its exact behaviour. Same default-argument
    /// pattern as `defaultScheduler()` for the same `Mockable` FIFO-shadowing reason.
    private static func defaultVisibility() -> MockMonitorVisibility {
        let visibility = MockMonitorVisibility()
        given(visibility).mainWindowVisible.willReturn(true)
        given(visibility).menuBarPopoverOpen.willReturn(false)
        return visibility
    }

    func makeSUT(
        toolEnvironment: MockToolEnvironmentRepository = MockToolEnvironmentRepository(),
        snapshotRepository: MockTaskSnapshotRepository = MockTaskSnapshotRepository(),
        eventStreamRepository: MockEventStreamRepository = MockEventStreamRepository(),
        finishNotifier: MockFinishNotifier = MockFinishNotifier(),
        scheduler: MockScheduling = TaskListRepositoryImplTests.defaultScheduler(),
        visibility: MockMonitorVisibility = TaskListRepositoryImplTests.defaultVisibility(),
        invalidationSource: (any TaskListInvalidationSource)? = nil
    ) -> TaskListRepositoryImpl {
        given(snapshotRepository).evict(keeping: .any).willReturn()
        given(snapshotRepository).refresh(.any).willReturn()
        given(snapshotRepository).refresh(ids: .any).willReturn()
        given(snapshotRepository).snapshot(.any).willReturn(nil)
        given(eventStreamRepository).leasedTaskIDs.willReturn([])
        given(finishNotifier).notify(.any, titleFor: .any).willReturn()
        given(toolEnvironment).discoverEnvironment().willReturn(DiscoveryResult(loginPath: nil, uv: nil))
        return TaskListRepositoryImpl(
            toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository,
            eventStreamRepository: eventStreamRepository, finishNotifier: finishNotifier, scheduler: scheduler,
            visibility: visibility, invalidationSource: invalidationSource ?? PollingTaskListInvalidationSource(scheduler: scheduler),
            compatibilityCheck: { _ in .success(()) }
        )
    }

    // MARK: MS-LIST-4 — refresh coalescing

    @Test func givenARefreshRequestedWhileOneIsInFlight_whenItFinishes_thenItRunsAgainOnce() async {
        // given — a runner that blocks the first call until released, so a second `refresh()` call
        // is guaranteed to observe "already in flight".
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let callCount = LockedBox(0)
        let gate = AsyncGate()
        let runner = StubProcessRunner { _ in
            callCount.mutate { $0 += 1 }
            if callCount.value == 1 { gate.waitSync() }
            return .success(historyStdout(#"{"v":2,"tasks":[]}"#))
        }
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: PositiveCtlRunner(runner))))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when
        let firstRefresh = Task { await sut.refresh() }
        await waitUntil { callCount.value >= 1 }
        let secondRefresh = Task { await sut.refresh() }
        await waitUntil(timeout: 5) { sut.coalescedCallCount >= 1 } // the second call joined the in-flight pass
        gate.open()
        await firstRefresh.value
        await secondRefresh.value

        // then — the in-flight call ran again once more for the coalesced request, not once per
        // caller running independently (which would race arbitrarily higher).
        #expect(callCount.value == 4)
    }

    @Test func givenAFailedListing_whenRefreshed_thenStaleTasksAndSnapshotsAreKeptAndOnlyListErrorChanges() async {
        // given: seed one good listing first. `ctl()` reads from a mutable box rather than being
        // re-stubbed with `given` between calls — see the note in `TaskSnapshotRepositoryImplTests`
        // on why re-`given`-ing the same member does not reliably swap the next call's answer.
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let resultBox = LockedBox<Result<CtlClient, ToolError>>(.success(ctlClient(listing: ["a"])))
        given(toolEnvironment).ctl().willProduce { resultBox.value }
        let sut = makeSUT(toolEnvironment: toolEnvironment)
        await sut.refresh()
        #expect(sut.tasks.map(\.taskID) == ["a"])
        #expect(sut.listError == nil)

        // when: the next refresh fails to locate ctl at all.
        resultBox.mutate { $0 = .failure(.notFound(tool: "harflow-ctl", searched: [])) }
        await sut.refresh()

        // then
        #expect(sut.tasks.map(\.taskID) == ["a"])
        guard case .notFound = sut.listError else {
            Issue.record("expected listError to be set to .notFound")
            return
        }
    }

}
