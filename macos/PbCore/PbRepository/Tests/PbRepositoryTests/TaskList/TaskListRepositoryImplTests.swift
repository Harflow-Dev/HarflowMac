import Combine
import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
import PbTestUtilities
import Testing

@Suite struct TaskListRepositoryImplTests {

    // MARK: Fixtures

    func ctlClient(listing: [String], runner: StubProcessRunner? = nil) -> CtlClient {
        let payload = "[" + listing.map {
            #"{"task_id":"\#($0)","status":"running","backend":"claude"}"#
        }
.joined(separator: ",") + "]"
        let stub = runner ?? StubProcessRunner(output: stdout(#"{"v":2,"tasks":\#(payload)}"#))
        return CtlClient(executable: "/bin/echo", environment: [:], runner: stub)
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

    func makeSUT(
        toolEnvironment: MockToolEnvironmentRepository = MockToolEnvironmentRepository(),
        snapshotRepository: MockTaskSnapshotRepository = MockTaskSnapshotRepository(),
        eventStreamRepository: MockEventStreamRepository = MockEventStreamRepository(),
        finishNotifier: MockFinishNotifier = MockFinishNotifier(),
        scheduler: MockScheduling = TaskListRepositoryImplTests.defaultScheduler()
    ) -> TaskListRepositoryImpl {
        given(snapshotRepository).evict(keeping: .any).willReturn()
        given(snapshotRepository).refresh(.any).willReturn()
        given(snapshotRepository).snapshot(.any).willReturn(nil)
        given(eventStreamRepository).leasedTaskIDs.willReturn([])
        given(finishNotifier).notify(.any, titleFor: .any).willReturn()
        given(toolEnvironment).discoverEnvironment().willReturn(DiscoveryResult(loginPath: nil, uv: nil))
        return TaskListRepositoryImpl(
            toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository,
            eventStreamRepository: eventStreamRepository, finishNotifier: finishNotifier, scheduler: scheduler
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
            return .success(stdout(#"{"v":2,"tasks":[]}"#))
        }
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when
        let firstRefresh = Task { await sut.refresh() }
        await waitUntil { callCount.value >= 1 }
        let secondRefresh = Task { await sut.refresh() }
        try? await Task.sleep(for: .milliseconds(50)) // let the second call observe "in flight"
        gate.open()
        await firstRefresh.value
        await secondRefresh.value

        // then — the in-flight call ran again once more for the coalesced request, not once per
        // caller running independently (which would race arbitrarily higher).
        #expect(callCount.value == 2)
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
        resultBox.mutate { $0 = .failure(.notFound(tool: "polybridge-ctl", searched: [])) }
        await sut.refresh()

        // then
        #expect(sut.tasks.map(\.taskID) == ["a"])
        guard case .notFound = sut.listError else {
            Issue.record("expected listError to be set to .notFound")
            return
        }
    }

    // MARK: MS-LIST-2 — throttle, not debounce

    @Test func givenABurstOfPhaseFileEvents_whenThrottled_thenOneRefreshFiresAfterOneSecondNotStarved() async {
        // given
        let scheduler = MockScheduling()
        // A `LockedBox`, not a plain `var`: `Mockable`'s `Mocker.mock(...)` calls `addInvocation`
        // (making the call visible to `verify(...).calledEventually`) *before* it runs this
        // `willProduce` closure — so `calledEventually` can observe the invocation and return before
        // `capturedWork` is actually set. A plain unsynchronized `var` mutated from the FSEvents
        // callback thread and read from the test's thread would also be a data race independent of
        // that ordering issue. Waiting on this box directly (below) closes both problems.
        let capturedWork = LockedBox<(@Sendable () -> Void)?>(nil)
        given(scheduler).schedule(after: .value(1), execute: .any).willProduce { _, work in
            capturedWork.mutate { $0 = work }
            return AnyCancellable {}
        }
        // `startWatching()` creates the `DirectoryWatcher` and calls `watcher.start()` *before*
        // calling `scheduleRepeating` — so capturing this call (even though this test never invokes
        // the captured closure) is a reliable signal that `startWatching()` has actually run and the
        // real FSEvents watcher is attached. Without waiting for it, the burst-file writes below can
        // land before the watcher exists and never trigger a throttled refresh at all — the same
        // `hasListed`-becomes-true-before-`startWatching()` race documented on `TaskListRepositoryImpl.start()`.
        let repeatingCaptured = LockedBox(false)
        given(scheduler).scheduleRepeating(every: .any, execute: .any).willProduce { _, _ in
            repeatingCaptured.mutate { $0 = true }
            return AnyCancellable {}
        }
        given(scheduler).now().willReturn(Date())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PbRepoTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(dir.path)
        let listCallCount = LockedBox(0)
        let runner = StubProcessRunner { _ in
            listCallCount.mutate { $0 += 1 }
            return .success(stdout(#"{"v":2,"tasks":[]}"#))
        }
        given(toolEnvironment).ctl().willReturn(.success(ctlClient(listing: [], runner: runner)))
        let sut = makeSUT(toolEnvironment: toolEnvironment, scheduler: scheduler)
        sut.start()
        await waitUntil { sut.hasListed }
        await waitUntil { repeatingCaptured.value }
        #expect(repeatingCaptured.value)
        let listCallsAfterStart = listCallCount.value

        // when — simulate a burst of FSEvents arriving on the tasks folder by touching a
        // `.meta.json` file repeatedly, in this test's own isolated directory. Each write should
        // schedule at most one pending refresh. FSEvents itself coalesces with a 0.3 s latency
        // (`DirectoryWatcher`'s own `FSEventStreamCreate` parameter), so the wait below polls rather
        // than sleeping a fixed, possibly-too-short interval.
        for _ in 0 ..< 5 {
            try? "x".write(toFile: dir.path + "/burst.meta.json", atomically: true, encoding: .utf8)
        }

        // then — the scheduler's one-shot `schedule(after: 1, …)` is armed exactly once for the
        // whole burst (a debounce would keep re-arming and never fire)…
        await verify(scheduler).schedule(after: .value(1), execute: .any).calledEventually(1, before: .seconds(3))
        // `calledEventually` only proves the call was *recorded* — `Mocker.mock(...)` records the
        // invocation before running `willProduce`, so `capturedWork` itself must be waited on
        // separately before it is safe to fire (see the note on its declaration above).
        await waitUntil(timeout: 3) { capturedWork.value != nil }
        #expect(capturedWork.value != nil)
        // …and firing that one captured work item actually produces a real refresh — the burst was
        // not starved, it was merely coalesced into a single pending refresh.
        capturedWork.value?()
        await waitUntil(timeout: 3) { listCallCount.value > listCallsAfterStart }
        #expect(listCallCount.value > listCallsAfterStart)
        // `sut` is only reachable from here on through weak captures inside the scheduler/watcher
        // closures; without an explicit late use, ARC is free to deallocate it as soon as its last
        // textual reference above is reached, which would silently no-op every closure that follows.
        withExtendedLifetime(sut) {}
    }

}
