import Combine
import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
import PbTestUtilities
import Testing

/// `.serialized`: several tests in this suite gate a `willProduce`/`StubProcessRunner` stub on a
/// blocking `AsyncGate` (`DispatchSemaphore`) to force a deterministic race — the same technique
/// `TaskListRepositoryImplTests`/`ToolEnvironmentRepositoryImplTests` already use. Mockable's
/// `willProduce` only accepts a *synchronous* closure even for an `async` member (confirmed: an
/// `async`, non-blocking closure there fails to typecheck), so a blocking wait is the only available
/// mechanism — and running several of them concurrently (this suite's own, on top of every other
/// gated test elsewhere in this package) risks exhausting Swift's cooperative thread pool. Forcing
/// this suite serial bounds its own contribution to that shared pool to one blocked thread at a time.
@Suite(.serialized) struct BackendsRepositoryImplTests {

    // MARK: Fixtures

    /// A `MockScheduling` pre-stubbed with harmless defaults, mirroring
    /// `TaskListRepositoryImplTests.defaultScheduler()` — evaluated fresh per call so each test gets
    /// its own instance.
    private static func defaultScheduler() -> MockScheduling {
        let scheduler = MockScheduling()
        given(scheduler).now().willReturn(Date())
        return scheduler
    }

    func makeSUT(
        toolEnvironment: MockToolEnvironmentRepository = MockToolEnvironmentRepository(),
        installRepository: MockInstallRepository = MockInstallRepository(),
        scheduler: MockScheduling = BackendsRepositoryImplTests.defaultScheduler(),
        stubDiscovery: Bool = true
    ) -> BackendsRepositoryImpl {
        // `stubDiscovery: false` lets a caller register its own `discoverEnvironment()` stub (e.g. a
        // gated one) before calling this — a second `given` registered afterward here would either
        // shadow it or race it, per the FIFO-stub pitfall noted elsewhere in this package's tests.
        if stubDiscovery {
            given(toolEnvironment).discoverEnvironment().willReturn(DiscoveryResult(loginPath: nil, uv: nil))
        }
        given(installRepository).statePublisher().willReturn(Empty().eraseToAnyPublisher())
        return BackendsRepositoryImpl(toolEnvironment: toolEnvironment, installRepository: installRepository, scheduler: scheduler)
    }

    func ctlClient(backends: [(String, Bool)], runner: StubProcessRunner? = nil) -> CtlClient {
        let payload = "[" + backends.map { #"{"backend":"\#($0.0)","binary":"\#($0.0)","installed":\#($0.1)}"# }.joined(separator: ",") + "]"
        let stub = runner ?? StubProcessRunner(output: stdout(#"{"v":2,"backends":\#(payload)}"#))
        return CtlClient(executable: "/bin/echo", environment: [:], runner: stub)
    }

    // MARK: Success

    @Test func givenASuccessfulFetch_whenRefreshed_thenTheCatalogIsAvailableInRegistryOrder() async {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willReturn(.success(ctlClient(backends: [("claude", true), ("codex", false)])))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when
        await sut.refresh()

        // then
        #expect(sut.catalog.state == .available)
        #expect(sut.catalog.entries.map(\.backend) == ["claude", "codex"])
        #expect(sut.catalog.entries.map(\.installed) == [true, false])
    }

    // MARK: Degraded — ctl missing

    @Test func givenCtlNotFound_whenRefreshed_thenTheCatalogDegradesToUnknownRatherThanNotInstalled() async {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willReturn(.failure(.notFound(tool: "polybridge-ctl", searched: [])))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when
        await sut.refresh()

        // then
        #expect(sut.catalog.state == .degraded)
        #expect(sut.catalog.entries.isEmpty)
    }

    // MARK: Degraded — unsupported command (older ctl)

    @Test func givenAnOlderCtlReportingTheCommandUnsupported_whenRefreshed_thenItDegradesKeepingLastKnownNamesAsUnknown() async {
        // given — a successful fetch first, then an older-ctl-shaped failure (JSON usage-error form).
        let toolEnvironment = MockToolEnvironmentRepository()
        let resultBox = LockedBox<Result<CtlClient, ToolError>>(.success(ctlClient(backends: [("claude", true)])))
        given(toolEnvironment).ctl().willProduce { resultBox.value }
        let sut = makeSUT(toolEnvironment: toolEnvironment)
        await sut.refresh()
        #expect(sut.catalog.state == .available)

        // when
        resultBox.mutate { $0 = .failure(.unsupportedCommand(tool: "polybridge-ctl", command: "backends", detail: "invalid choice")) }
        await sut.refresh()

        // then — the name survives, but its install state is no longer claimed as known.
        #expect(sut.catalog.state == .degraded)
        #expect(sut.catalog.entries.map(\.backend) == ["claude"])
        #expect(sut.catalog.entries.map(\.installed) == [nil])
    }

    // MARK: Degraded — malformed / timeout / unsupported version

    @Test func givenAMalformedAnUnsupportedVersionAndATimedOutAnswer_whenRefreshed_thenAllThreeDegradeRatherThanError() async {
        for failure: ToolError in [
            .unreadable(tool: "polybridge-ctl", exitCode: 1, stderr: "boom"),
            .unsupportedVersion(tool: "polybridge-ctl", version: "7"),
            .timedOut(tool: "polybridge-ctl backends", seconds: 30)
        ] {
            // given
            let toolEnvironment = MockToolEnvironmentRepository()
            given(toolEnvironment).ctl().willReturn(.failure(failure))
            let sut = makeSUT(toolEnvironment: toolEnvironment)

            // when
            await sut.refresh()

            // then
            #expect(sut.catalog.state == .degraded, "\(failure) should degrade")
        }
    }

    // MARK: Refresh coalescing / stale-result guard

    @Test func givenARefreshRequestedWhileOneIsInFlight_whenItFinishes_thenItRunsAgainOnceAndTheLatestAnswerWins() async {
        // given — a runner that blocks the first call until released, so a second `refresh()` call
        // is guaranteed to observe "already in flight"; the listing changes from pass to pass so the
        // final published catalog is distinguishably the *later* one, never the first.
        let toolEnvironment = MockToolEnvironmentRepository()
        let callCount = LockedBox(0)
        let gate = AsyncGate()
        let runner = StubProcessRunner { _ in
            let pass = callCount.value + 1
            callCount.mutate { $0 = pass }
            if pass == 1 { gate.waitSync() }
            return .success(stdout(#"{"v":2,"backends":[{"backend":"pass\#(pass)","binary":"pass\#(pass)","installed":true}]}"#))
        }
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when
        let first = Task { await sut.refresh() }
        await waitUntil { callCount.value >= 1 }
        let second = Task { await sut.refresh() }
        try? await Task.sleep(for: .milliseconds(50)) // let the second call observe "in flight"
        gate.open()
        await first.value
        await second.value

        // then — coalesced into exactly one extra pass, and the published catalog is the later one.
        #expect(callCount.value == 2)
        #expect(sut.catalog.entries.map(\.backend) == ["pass2"])
    }

    // MARK: Startup

    @Test func givenStart_whenCalledTwice_thenOnlyTheFirstCallDiscoversAndFetches() async {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        let fetchCount = LockedBox(0)
        let runner = StubProcessRunner { _ in
            fetchCount.mutate { $0 += 1 }
            return .success(stdout(#"{"v":2,"backends":[]}"#))
        }
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when
        sut.start()
        sut.start()
        await waitUntil { fetchCount.value >= 1 }
        try? await Task.sleep(for: .milliseconds(100))

        // then
        #expect(fetchCount.value == 1)
        verify(toolEnvironment).discoverEnvironment().called(1)
    }

    // MARK: App activation — bounded to once per 60 s

    @Test func givenAppActivatedTwiceWithinSixtySeconds_whenCalled_thenOnlyTheFirstRefreshes() async {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        let fetchCount = LockedBox(0)
        let runner = StubProcessRunner { _ in
            fetchCount.mutate { $0 += 1 }
            return .success(stdout(#"{"v":2,"backends":[]}"#))
        }
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let scheduler = MockScheduling()
        let now = LockedBox(Date())
        given(scheduler).now().willProduce { now.value }
        let sut = makeSUT(toolEnvironment: toolEnvironment, scheduler: scheduler)

        // when
        sut.appDidBecomeActive()
        await waitUntil { fetchCount.value >= 1 }
        now.mutate { $0 = $0.addingTimeInterval(30) }
        sut.appDidBecomeActive()
        try? await Task.sleep(for: .milliseconds(100))

        // then
        #expect(fetchCount.value == 1)
    }

    @Test func givenAppActivatedAfterSixtySeconds_whenCalled_thenItRefreshesAgain() async {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        let fetchCount = LockedBox(0)
        let runner = StubProcessRunner { _ in
            fetchCount.mutate { $0 += 1 }
            return .success(stdout(#"{"v":2,"backends":[]}"#))
        }
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let scheduler = MockScheduling()
        let now = LockedBox(Date())
        given(scheduler).now().willProduce { now.value }
        let sut = makeSUT(toolEnvironment: toolEnvironment, scheduler: scheduler)

        // when
        sut.appDidBecomeActive()
        await waitUntil { fetchCount.value >= 1 }
        now.mutate { $0 = $0.addingTimeInterval(61) }
        sut.appDidBecomeActive()
        await waitUntil { fetchCount.value >= 2 }

        // then
        #expect(fetchCount.value == 2)
    }

    // MARK: Generation guard (Code review round 1, finding 2)

    @Test func givenSettingsChangedWhileAFetchIsInFlight_whenItCompletes_thenTheStaleResultIsNeverPublished() async {
        // given — pass 1 blocks until released. By the time it resumes, `settingsChanged()` has
        // already bumped the generation and armed a coalesced pass 2, so pass 1's own answer is
        // stale before it even returns and must never reach the publisher — not even transiently.
        // `StubProcessRunner`'s own `answer` closure is synchronous by design (mirrors
        // `MonitorCoreTests/TestSupport.swift`'s `RecordingRunner`), so this uses `AsyncGate`
        // (a blocking `DispatchSemaphore`) exactly like the pre-existing coalescing test above —
        // there is no `async` suspension point available inside it to gate any other way.
        let toolEnvironment = MockToolEnvironmentRepository()
        let callCount = LockedBox(0)
        let gate = AsyncGate()
        let runner = StubProcessRunner { _ in
            let pass = callCount.value + 1
            callCount.mutate { $0 = pass }
            if pass == 1 { gate.waitSync() }
            return .success(stdout(#"{"v":2,"backends":[{"backend":"pass\#(pass)","binary":"pass\#(pass)","installed":true}]}"#))
        }
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = makeSUT(toolEnvironment: toolEnvironment)
        let published = LockedBox<[BackendCatalog]>([])
        let cancellable = sut.catalogPublisher().sink { catalog in published.mutate { $0.append(catalog) } }

        // when
        let firstRefresh = Task { await sut.refresh() }
        await waitUntil { callCount.value >= 1 }
        sut.settingsChanged()
        try? await Task.sleep(for: .milliseconds(50)) // let settingsChanged's own refresh() coalesce
        gate.open()
        await firstRefresh.value
        await waitUntil { published.value.contains { $0.entries.map(\.backend) == ["pass2"] } }

        // then — pass 1's answer never appears in the publisher's history, only the initial empty
        // snapshot and pass 2's.
        #expect(!published.value.contains { $0.entries.map(\.backend) == ["pass1"] })
        #expect(sut.catalog.entries.map(\.backend) == ["pass2"])
        cancellable.cancel()
    }

    @Test func givenAnInstallSuccessWhileAFetchIsInFlight_whenItCompletes_thenTheStaleResultIsNeverPublished() async {
        // given — same shape as the `settingsChanged()` case above, but the bump comes from the
        // install pipeline reaching `.installed` instead.
        let toolEnvironment = MockToolEnvironmentRepository()
        let callCount = LockedBox(0)
        let gate = AsyncGate()
        let runner = StubProcessRunner { _ in
            let pass = callCount.value + 1
            callCount.mutate { $0 = pass }
            if pass == 1 { gate.waitSync() }
            return .success(stdout(#"{"v":2,"backends":[{"backend":"pass\#(pass)","binary":"pass\#(pass)","installed":true}]}"#))
        }
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let installRepository = MockInstallRepository()
        let stateSubject = PassthroughSubject<InstallState, Never>()
        given(installRepository).statePublisher().willReturn(stateSubject.eraseToAnyPublisher())
        let sut = makeSUT(toolEnvironment: toolEnvironment, installRepository: installRepository)
        sut.start() // subscribes to install state; discovery is unblocked (default stub), so this settles fast.
        await waitUntil { callCount.value >= 1 }
        let published = LockedBox<[BackendCatalog]>([])
        let cancellable = sut.catalogPublisher().sink { catalog in published.mutate { $0.append(catalog) } }

        // when — start()'s own initial fetch (pass 1) is blocked on the gate; install success fires
        // while it's in flight.
        stateSubject.send(.installed)
        try? await Task.sleep(for: .milliseconds(50))
        gate.open()
        await waitUntil { published.value.contains { $0.entries.map(\.backend) == ["pass2"] } }

        // then
        #expect(!published.value.contains { $0.entries.map(\.backend) == ["pass1"] })
        #expect(sut.catalog.entries.map(\.backend) == ["pass2"])
        cancellable.cancel()
    }

    // MARK: Initial-discovery gate (Code review round 1, finding 3)

    @Test func givenStartsInitialDiscoveryStillPending_whenAppDidBecomeActiveFires_thenItIsANoOp() async {
        // given — `discoverEnvironment()` is gated so `start()`'s own initial pass never finishes
        // during this test's first phase. Mockable's `willProduce` only accepts a *synchronous*
        // closure even for this `async` member (confirmed: an `async` closure body fails to
        // typecheck there), so `AsyncGate` (a blocking `DispatchSemaphore`) is the only available
        // mechanism — same as the pre-existing coalescing test above. `stubDiscovery: false` keeps
        // `makeSUT()` from registering its own (unblocked) stub over this one.
        let toolEnvironment = MockToolEnvironmentRepository()
        let discoveryGate = AsyncGate()
        given(toolEnvironment).discoverEnvironment().willProduce {
            discoveryGate.waitSync()
            return DiscoveryResult(loginPath: nil, uv: nil)
        }
        let fetchCount = LockedBox(0)
        let runner = StubProcessRunner { _ in
            fetchCount.mutate { $0 += 1 }
            return .success(stdout(#"{"v":2,"backends":[]}"#))
        }
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = makeSUT(toolEnvironment: toolEnvironment, stubDiscovery: false)

        // when — activation fires while discovery is still pending.
        sut.start()
        sut.appDidBecomeActive()
        try? await Task.sleep(for: .milliseconds(100))

        // then — no fetch at all yet: the no-op activation did nothing, and start's own refresh is
        // still waiting on discovery.
        #expect(fetchCount.value == 0)

        // when — discovery finally completes.
        discoveryGate.open()
        await waitUntil { fetchCount.value >= 1 }
        try? await Task.sleep(for: .milliseconds(100))

        // then — exactly one fetch: start's own follow-up refresh, never the blocked activation.
        #expect(fetchCount.value == 1)
    }

    @Test func givenStartsInitialDiscoveryStillPending_whenSettingsChangedFires_thenItIsANoOp() async {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        let discoveryGate = AsyncGate()
        given(toolEnvironment).discoverEnvironment().willProduce {
            discoveryGate.waitSync()
            return DiscoveryResult(loginPath: nil, uv: nil)
        }
        let fetchCount = LockedBox(0)
        let runner = StubProcessRunner { _ in
            fetchCount.mutate { $0 += 1 }
            return .success(stdout(#"{"v":2,"backends":[]}"#))
        }
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = makeSUT(toolEnvironment: toolEnvironment, stubDiscovery: false)

        // when
        sut.start()
        sut.settingsChanged()
        try? await Task.sleep(for: .milliseconds(100))

        // then
        #expect(fetchCount.value == 0)

        // when
        discoveryGate.open()
        await waitUntil { fetchCount.value >= 1 }
        try? await Task.sleep(for: .milliseconds(100))

        // then
        #expect(fetchCount.value == 1)
    }

    @Test func givenRefreshCalledDirectlyWithoutStart_whenCalled_thenTheInitialDiscoveryGateNeverApplies() async {
        // given — a SUT that never had `start()` called on it at all: the gate is keyed on `started`,
        // so a direct `refresh()` (as every other test in this file relies on) must keep working.
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willReturn(.success(ctlClient(backends: [("claude", true)])))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when
        sut.settingsChanged()

        // then
        await waitUntil { sut.catalog.state == .available }
        #expect(sut.catalog.entries.map(\.backend) == ["claude"])
    }

    // MARK: Tool-directory change

    @Test func givenSettingsChanged_whenCalled_thenItRefreshes() async {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willReturn(.success(ctlClient(backends: [("claude", true)])))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when
        sut.settingsChanged()

        // then
        await waitUntil { sut.catalog.state == .available }
        #expect(sut.catalog.entries.map(\.backend) == ["claude"])
    }

    // MARK: Install success

    @Test func givenTheInstallStateReachesInstalled_whenObserved_thenItRefreshes() async {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willReturn(.success(ctlClient(backends: [("claude", true)])))
        let installRepository = MockInstallRepository()
        let stateSubject = PassthroughSubject<InstallState, Never>()
        given(installRepository).statePublisher().willReturn(stateSubject.eraseToAnyPublisher())
        let sut = makeSUT(toolEnvironment: toolEnvironment, installRepository: installRepository)
        sut.start()
        await waitUntil { sut.catalog.state == .available }

        // when — a later, unrelated state change is a no-op; only `.installed` triggers a refresh.
        stateSubject.send(.needsGit)
        stateSubject.send(.installed)

        // then
        await waitUntil { sut.catalog.entries.map(\.backend) == ["claude"] }
        #expect(sut.catalog.state == .available)
    }

    @Test func givenCatalogSubscriber_whenEqualRefreshesRepeat_thenChangesAndRecoveryRemainVisible() async {
        // given
        let environment = MockToolEnvironmentRepository()
        let result = LockedBox<Result<CtlClient, ToolError>>(.success(ctlClient(backends: [("fixture", false)])))
        given(environment).ctl().willProduce { result.value }
        let sut = makeSUT(toolEnvironment: environment)
        let received = LockedBox<[BackendCatalog]>([])
        let token = sut.catalogPublisher().sink { value in received.mutate { $0.append(value) } }
        // when
        await sut.refresh()
        await sut.refresh()
        result.mutate { $0 = .success(ctlClient(backends: [("fixture", true)])) }
        await sut.refresh()
        result.mutate { $0 = .success(ctlClient(backends: [("fixture", false)])) }
        await sut.refresh()
        result.mutate { $0 = .failure(.notFound(tool: "polybridge-ctl", searched: [])) }
        await sut.refresh()
        await sut.refresh()
        result.mutate { $0 = .success(ctlClient(backends: [("fixture", false)])) }
        await sut.refresh()
        // then
        #expect(received.value.map(\.state) == [.loading, .available, .available, .available, .degraded, .available])
        #expect(received.value.dropFirst().map { $0.entries.first?.installed } == [false, true, false, nil, false])
        verify(environment).ctl().called(7)
        withExtendedLifetime(token) {}
    }

}
