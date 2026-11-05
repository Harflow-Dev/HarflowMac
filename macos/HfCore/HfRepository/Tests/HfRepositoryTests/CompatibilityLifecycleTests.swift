import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
import Testing

@Suite struct CompatibilityLifecycleTests {
    @Test func givenActivityCompatibilityIsDelayed_whenTheLastLeaseIsReleased_thenNoLatePublicationOccurs() async {
        // given / when / then
        await verifyDelayedPublicCompatibility(activity: true)
    }

    @Test func givenSummaryCompatibilityIsDelayed_whenTheLastLeaseIsReleased_thenNoLatePublicationOccurs() async {
        // given / when / then
        await verifyDelayedPublicCompatibility(activity: false)
    }

    @Test func givenCompatibilityIsSuspended_whenSettingsChange_thenTheStaleCheckCannotLaunchCtl() async {
        let checker = SuspendedCompatibilityCheck()
        let runner = compatibleRunner { _ in .success(historyOutput(taskID: "current")) }
        let environment = taskListEnvironment(runner: runner)
        let sut = makeTaskList(environment: environment, compatibilityCheck: checker.call)
        let refresh = Task { await sut.refresh() }
        await checker.waitUntilCalled()
        sut.settingsChanged()
        checker.resumeNext(.success(()))
        await checker.waitUntilCompleted()
        #expect(runner.calls.isEmpty)
        await waitUntil { checker.callCount >= 2 }
        checker.resumeNext(.success(()))
        await refresh.value
        #expect(runner.calls.count == 4)
        #expect(runner.calls.map(\.arguments) == [
            ["version-info", "--json"],
            ["task-list-page", "--limit=100", "--json"],
            ["version-info", "--json"],
            ["task-list-page", "--limit=100", "--active-only", "--json"]
        ])
        #expect(sut.tasks.map(\.taskID) == ["current"])
    }

    @Test func givenActivityCompatibilityFails_whenTheLeaseIsAcquired_thenUnavailableStatePublishesWithoutEvents() async {
        // given / when / then
        await verifyPublicCompatibilityFailure(activity: true)
    }

    @Test func givenSummaryCompatibilityFails_whenTheLeaseIsAcquired_thenUnavailableStatePublishesWithoutEvents() async {
        // given / when / then
        await verifyPublicCompatibilityFailure(activity: false)
    }

    @Test func givenCtlListingIsOutstanding_whenSettingsChange_thenStaleListingCannotPublishOrStartObservation() async {
        let scheduler = CapturingScheduler()
        let firstListing = AsyncGate()
        let secondListing = AsyncGate()
        let callCount = LockedBox(0)
        let runner = compatibleRunner { call in
            if call.arguments.contains("--active-only") || call.arguments.contains(where: { $0.hasPrefix("--task-ids=") }) {
                return .success(historyOutput(taskID: nil))
            }
            let sequence = callCount.value + 1
            callCount.mutate { $0 = sequence }
            if sequence == 1 { firstListing.waitSync() } else { secondListing.waitSync() }
            return .success(historyOutput(taskID: sequence == 1 ? "stale" : "current"))
        }
        let environment = taskListEnvironment(runner: runner)
        let sut = makeTaskList(environment: environment, scheduler: scheduler)
        sut.start()
        await waitUntil { callCount.value >= 1 }
        sut.settingsChanged()
        firstListing.open()
        await waitUntil { callCount.value >= 2 }
        #expect(sut.tasks.isEmpty)
        #expect(sut.titles.isEmpty)
        #expect(sut.titleLoadPassCount == 0)
        #expect(scheduler.repeatIntervals.isEmpty)
        secondListing.open()
        await waitUntil { sut.tasks.map(\.taskID) == ["current"] }
    }

    @Test func givenInitialCompatibilityFails_whenScheduledRetrySucceeds_thenListingAndObservationStartOnlyAfterSuccess() async throws {
        let scheduler = CapturingScheduler()
        let runner = compatibleRunner { _ in .success(historyOutput(taskID: "recovered")) }
        let checker = LockedBox(0)
        let incompatibility = WireEnvelope.incompatibility("old runtime")
        let environment = taskListEnvironment(runner: runner)
        let sut = makeTaskList(environment: environment, scheduler: scheduler) { _ in
            checker.mutate { $0 += 1 }
            return checker.value == 1 ? .failure(incompatibility) : .success(())
        }
        sut.start()
        await waitUntil { checker.value == 1 && sut.listError != nil }
        #expect(runner.calls.isEmpty)
        #expect(sut.tasks.isEmpty)
        #expect(sut.listError?.message == incompatibility.message)
        #expect(sut.historyState.error?.message == incompatibility.message)
        #expect(scheduler.repeatIntervals.isEmpty)
        await waitUntil { scheduler.oneShotCount(interval: 10) == 1 }
        scheduler.fireFirstOneShot()
        await waitUntil { sut.tasks.map(\.taskID) == ["recovered"] && scheduler.repeatIntervals == [1] }
        #expect(!runner.calls.isEmpty)
    }

    @Test func givenPollClaimedBeforeRuntimeChange_whenStalePassBegins_thenItFailsBeforeProbeAndReleasesCoordinator() async {
        // given — step the real poll path immediately after its idle-only coordinator claim.
        let probes = LockedBox(0)
        let runner = compatibleRunner { _ in .success(historyOutput(taskID: "fresh")) }
        let sut = makeTaskList(environment: taskListEnvironment(runner: runner)) { _ in
            probes.mutate { $0 += 1 }
            return .success(())
        }
        let generation = sut.refreshGeneration()
        #expect(await sut.refreshCoordinator.tryBeginPollIfIdle())
        // Isolate the invalidated claim from runtimeBecameReady's separate legitimate refresh.
        sut.startLock.withLock { sut.compatibilityGeneration += 1 }
        // when
        let staleResult = await sut.runRefreshLoop(initialGeneration: generation)
        // then
        guard case .failure(let staleError) = staleResult else {
            Issue.record("stale poll unexpectedly succeeded")
            return
        }
        #expect(staleError == TaskListRepositoryImpl.supersededRefresh)
        #expect(probes.value == 0)
        #expect(runner.calls.isEmpty)
        #expect(await sut.refreshCoordinator.tryBeginPollIfIdle())
        let owed = await sut.refreshCoordinator.beginPass()
        #expect(!(await sut.refreshCoordinator.endPass(owed: owed, result: .success(()))))
        let freshResult = await sut.refreshAndWait()
        guard case .success = freshResult else {
            Issue.record("fresh barrier failed after superseded poll claim")
            return
        }
        #expect(probes.value == 1)
        #expect(sut.tasks.map(\.taskID) == ["fresh"])
    }

    @Test func givenClaimedPollAndPendingAction_whenRuntimeChangesBeforePass_thenWaiterResolvesSupersededAndFreshBarrierWorks() async {
        // given — no process or compatibility check has started after this poll claim.
        let probes = LockedBox(0)
        let runner = compatibleRunner { _ in .success(historyOutput(taskID: "fresh")) }
        let sut = makeTaskList(environment: taskListEnvironment(runner: runner)) { _ in
            probes.mutate { $0 += 1 }
            return .success(())
        }
        let generation = sut.refreshGeneration()
        #expect(await sut.refreshCoordinator.tryBeginPollIfIdle())
        let action = Task { await sut.refreshAndWait() }
        await waitUntil { sut.coalescedCallCount == 1 }
        // when — the real runtime-change entry adds legitimate current demand behind the claim.
        sut.runtimeBecameReady()
        await waitUntil { sut.coalescedCallCount == 2 }
        let staleResult = await sut.runRefreshLoop(initialGeneration: generation)
        let actionResult = await action.value
        // then — the after-registration pass owes a failure and cannot invoke the old runtime.
        guard case .failure(let staleError) = staleResult else {
            Issue.record("stale poll unexpectedly succeeded")
            return
        }
        #expect(staleError == TaskListRepositoryImpl.supersededRefresh)
        guard case .failure(let actionError) = actionResult else {
            Issue.record("action waiter unexpectedly succeeded on stale pass")
            return
        }
        #expect(actionError == TaskListRepositoryImpl.supersededRefresh)
        #expect(probes.value == 0)
        #expect(runner.calls.isEmpty)
        let freshResult = await sut.refreshAndWait()
        guard case .success = freshResult else {
            Issue.record("fresh barrier failed after superseded poll claim")
            return
        }
        #expect(probes.value == 1)
        #expect(runner.calls.map(\.arguments) == [
            ["version-info", "--json"],
            ["task-list-page", "--limit=100", "--json"],
            ["version-info", "--json"],
            ["task-list-page", "--limit=100", "--active-only", "--json"]
        ])
        #expect(sut.tasks.map(\.taskID) == ["fresh"])
    }

    private func taskListEnvironment(
        runner: StubProcessRunner, tasksDirectory: String = FileManager.default.temporaryDirectory.path
    ) -> MockToolEnvironmentRepository {
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(tasksDirectory)
        given(environment).discoverEnvironment().willReturn(DiscoveryResult(loginPath: nil, uv: nil))
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        return environment
    }

    private func makeTaskList(
        environment: MockToolEnvironmentRepository,
        scheduler: any Scheduling = NullScheduling(),
        compatibilityCheck: @escaping StoreCompatibilityCheck = { _ in .success(()) }
    ) -> TaskListRepositoryImpl {
        let snapshots = MockTaskSnapshotRepository()
        given(snapshots).evict(keeping: .any).willReturn()
        given(snapshots).refresh(.any).willReturn()
        given(snapshots).refresh(ids: .any).willReturn()
        let events = MockEventStreamRepository()
        given(events).leasedTaskIDs.willReturn([])
        let notifier = MockFinishNotifier()
        given(notifier).notify(.any, titleFor: .any).willReturn()
        let visibility = MockMonitorVisibility()
        given(visibility).mainWindowVisible.willReturn(true)
        given(visibility).menuBarPopoverOpen.willReturn(false)
        return TaskListRepositoryImpl(toolEnvironment: environment, snapshotRepository: snapshots,
            eventStreamRepository: events, finishNotifier: notifier, scheduler: scheduler, visibility: visibility,
            compatibilityCheck: compatibilityCheck)
    }

    private func historyOutput(taskID: String?) -> ProcessOutput {
        let items: [JSONValue] = taskID.map {
            [.object(["task_id": .string($0), "status": .string("running"), "backend": .string("claude"), "title": .string($0)])]
        } ?? []
        let page: [String: JSONValue] = ["items": .array(items), "next_cursor": .null, "has_more": .bool(false),
            "bootstrap_pending": .bool(false), "authority_incomplete": .bool(false), "history_incomplete": .bool(false),
            "counts_complete": .bool(true), "total_active_count": .number(Double(items.count)),
            "catalog_state": .object(["status": .string("ready"), "source": .string("task_catalog")])]
        let response: [String: JSONValue] = ["product": .string("harflow"), "format": .string("harflow.ctl"),
            "v": .number(1), "product_version": .string("0.0.1"), "result": .object(page)]
        return stdout(JSONValue.object(response).rendered())
    }

    private func verifyDelayedPublicCompatibility(activity: Bool) async {
        // given
        let gate = LifecycleProbeGate()
        let commands = LockedBox(0)
        let runner = LifecyclePublicRunner(gate: gate, commands: commands, incompatible: false)
        let tools = MockToolEnvironmentRepository()
        given(tools).ctl().willReturn(.success(CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)))
        let reader = LifecycleCompletionReader(base: BoundPublicEventObservationReader(tooling: tools))
        let repository = EventStreamRepositoryImpl(snapshotRepository: NullTaskSnapshotRepository(), scheduler: NullScheduling(),
            reader: reader, promptRepository: NullTaskPromptRepository(), delivery: { $0() })
        let publications = LockedBox<[EventObservationFrame]>([])
        let subscription = repository.observationPublisher(for: "task").sink { frame in publications.mutate { $0.append(frame) } }
        defer { subscription.cancel() }
        let lease = activity ? repository.acquire("task") : repository.acquireSummary("task")
        await waitUntil { gate.entered.value }
        // when
        lease.release()
        await gate.open()
        await waitUntil { reader.completed.value }
        // then
        #expect(commands.value == 0)
        #expect(repository.observation(for: "task").records.isEmpty)
        #expect(repository.observation(for: "task").summary.counts == nil)
        #expect(repository.eventsAvailability(for: "task") == .loading)
        #expect(publications.value.allSatisfy { $0.records.isEmpty && $0.summary.counts == nil })
        #expect(repository.leasedTaskIDs.isEmpty)
    }

    private func verifyPublicCompatibilityFailure(activity: Bool) async {
        // given
        let gate = LifecycleProbeGate()
        await gate.open()
        let commands = LockedBox(0)
        let runner = LifecyclePublicRunner(gate: gate, commands: commands, incompatible: true)
        let tools = MockToolEnvironmentRepository()
        given(tools).ctl().willReturn(.success(CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)))
        let reader = LifecycleCompletionReader(base: BoundPublicEventObservationReader(tooling: tools))
        let repository = EventStreamRepositoryImpl(snapshotRepository: NullTaskSnapshotRepository(), scheduler: NullScheduling(),
            reader: reader, promptRepository: NullTaskPromptRepository(), delivery: { $0() })
        let lease = activity ? repository.acquire("task") : repository.acquireSummary("task")
        defer { lease.release() }
        // when
        await waitUntil { repository.eventsAvailability(for: "task") == .unavailable }
        // then
        #expect(commands.value == 0)
        #expect(repository.observation(for: "task").history.reasons.contains(.unavailable))
        #expect(repository.observation(for: "task").summary.state == .unavailable)
        #expect(repository.observation(for: "task").summary.counts == nil)
        #expect(repository.events(for: "task").isEmpty)
        #expect(repository.items(for: "task").isEmpty)
    }
}

private final class SuspendedCompatibilityCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Result<Void, ToolError>, Never>] = []
    private var calls = 0
    private var completions = 0
    var callCount: Int { lock.withLock { calls } }

    var call: StoreCompatibilityCheck {
        { [self] _ in
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, ToolError>, Never>) in
                lock.withLock {
                    calls += 1
                    continuations.append(continuation)
                }
            }
            lock.withLock { completions += 1 }
            return result
        }
    }

    func waitUntilCalled() async { await waitUntil { callCount > 0 } }
    func waitUntilCompleted(count: Int = 1) async { await waitUntil { lock.withLock { completions >= count } } }

    func resumeNext(_ result: Result<Void, ToolError>) {
        let continuation = lock.withLock { continuations.isEmpty ? nil : continuations.removeFirst() }
        continuation?.resume(returning: result)
    }
}

private actor LifecycleProbeGate {
    let entered = LockedBox(false)
    let completed = LockedBox(false)
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered.mutate { $0 = true }
        if !opened { await withCheckedContinuation { continuation = $0 } }
        completed.mutate { $0 = true }
    }

    func open() { opened = true; continuation?.resume(); continuation = nil }
}

private struct LifecyclePublicRunner: ProcessRunning {
    let gate: LifecycleProbeGate
    let commands: LockedBox<Int>
    let incompatible: Bool
    func run(executable _: String, arguments: [String], environment: [String: String],
             currentDirectory _: String?, timeout _: Double) async -> Result<ProcessOutput, ToolError> {
        guard arguments.first == "version-info" else {
            commands.mutate { $0 += 1 }
            let raw: [String: JSONValue] = ["product": .string("harflow"), "format": .string("harflow.ctl"),
                "v": .number(1), "product_version": .string(HarflowVersion.current), "result": .object(ObservationFixtures.page().raw)]
            return .success(stdout(JSONValue.object(raw).rendered()))
        }
        await gate.wait()
        let root = RuntimeCompatibilityContext.derived(environment: environment).expectedStateRoot
        let format = incompatible ? "unsupported.version-info" : "harflow.version-info"
        return .success(stdout("""
            {"product":"harflow","format":"\(format)","v":1,"product_version":"\(HarflowVersion.current)",
            "component":"engine","state_root":"\(root)",
            "contracts":{"ctl":{"format":"harflow.ctl","v":1},"events":{"format":"harflow.event","v":1}},
            "capabilities":["ctl.v1","events.v1","task-event-page.v1"],"os":"darwin","architecture":"arm64"}
            """))
    }
}

private struct LifecycleCompletionReader: PublicEventObservationReader {
    let base: BoundPublicEventObservationReader
    let completed = LockedBox(false)
    func read(taskID: String, position: TaskEventPagePosition,
              operationIsCurrent: @escaping @Sendable () -> Bool) async -> Result<TaskEventPage, ToolError> {
        let result = await base.read(taskID: taskID, position: position, operationIsCurrent: operationIsCurrent)
        completed.mutate { $0 = true }
        return result
    }
}
