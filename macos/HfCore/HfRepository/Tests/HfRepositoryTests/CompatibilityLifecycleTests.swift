import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
import Testing

@Suite struct CompatibilityLifecycleTests {
    @Test func givenActivityCompatibilityIsDelayed_whenTheLastLeaseIsReleased_thenNoLatePublicationOccurs() async throws {
        let fixture = try EventFixture()
        defer { fixture.remove() }
        let baseline = EventStreamRepositoryImpl(toolEnvironment: fixture.environment(), snapshotRepository: NullTaskSnapshotRepository(),
            scheduler: NullScheduling(), compatibilityCheck: { _ in .success(()) })
        let baselineLease = baseline.acquire(fixture.taskID)
        await waitUntil { baseline.events(for: fixture.taskID).count == 1 }
        baselineLease.release()
        let checker = SuspendedCompatibilityCheck()
        let environment = fixture.environment()
        let snapshots = MockTaskSnapshotRepository()
        given(snapshots).refresh(.any).willReturn()
        let initialLoads = EventInitialLoadQueue(limit: 1)
        let blocker = QueueBlocker()
        initialLoads.submit(id: UUID()) { completion in blocker.completion = completion }
        await waitUntil { blocker.completion != nil }
        let repository = EventStreamRepositoryImpl(toolEnvironment: environment, snapshotRepository: snapshots,
            scheduler: NullScheduling(), initialLoads: initialLoads, compatibilityCheck: checker.call)
        let lease = repository.acquire(fixture.taskID)
        await checker.waitUntilCalled()
        await waitUntil { checker.callCount == 2 }
        let publications = LockedBox<[[TimelineItem]]>([])
        let subscription = repository.itemsPublisher(for: fixture.taskID).sink { value in
            publications.mutate { $0.append(value) }
        }
        lease.release()
        checker.resumeNext(.success(()))
        checker.resumeNext(.success(()))
        await checker.waitUntilCompleted(count: 2)
        await drainTasks()
        let sentinel = QueueBlocker()
        initialLoads.submit(id: UUID()) { completion in
            sentinel.completion = completion
            sentinel.completed = true
            completion()
        }
        blocker.release()
        await waitUntil { sentinel.completed }
        await drainTasks()
        #expect(repository.events(for: fixture.taskID).isEmpty)
        #expect(repository.items(for: fixture.taskID).isEmpty)
        #expect(repository.eventsAvailability(for: fixture.taskID) == .loading)
        #expect(!publications.value.contains { !$0.isEmpty })
        subscription.cancel()
    }

    @Test func givenSummaryCompatibilityIsDelayed_whenTheLastLeaseIsReleased_thenNoLatePublicationOccurs() async throws {
        let fixture = try EventFixture()
        defer { fixture.remove() }
        let baseline = EventStreamRepositoryImpl(toolEnvironment: fixture.environment(), snapshotRepository: NullTaskSnapshotRepository(),
            scheduler: NullScheduling(), compatibilityCheck: { _ in .success(()) })
        let baselineLease = baseline.acquireSummary(fixture.taskID)
        await waitUntil { baseline.summary(for: fixture.taskID).availability == .available }
        baselineLease.release()
        let checker = SuspendedCompatibilityCheck()
        let environment = fixture.environment()
        let initialLoads = EventInitialLoadQueue(limit: 1)
        let blocker = QueueBlocker()
        initialLoads.submit(id: UUID()) { completion in blocker.completion = completion }
        await waitUntil { blocker.completion != nil }
        let repository = EventStreamRepositoryImpl(toolEnvironment: environment, snapshotRepository: NullTaskSnapshotRepository(),
            scheduler: NullScheduling(), initialLoads: initialLoads, compatibilityCheck: checker.call)
        let lease = repository.acquireSummary(fixture.taskID)
        await checker.waitUntilCalled()
        await waitUntil { checker.callCount == 1 }
        let publications = LockedBox<[EventSummary]>([])
        let subscription = repository.summaryPublisher(for: fixture.taskID).sink { value in
            publications.mutate { $0.append(value) }
        }
        lease.release()
        checker.resumeNext(.success(()))
        await checker.waitUntilCompleted()
        await drainTasks()
        let sentinel = QueueBlocker()
        initialLoads.submit(id: UUID()) { completion in
            sentinel.completion = completion
            sentinel.completed = true
            completion()
        }
        blocker.release()
        await waitUntil { sentinel.completed }
        await drainTasks()
        #expect(repository.summary(for: fixture.taskID).availability == .loading)
        #expect(repository.history(for: fixture.taskID).error == nil)
        #expect(publications.value.allSatisfy { $0.availability == .loading && $0.files.isEmpty })
        subscription.cancel()
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

    @Test func givenActivityCompatibilityFails_whenTheLeaseIsAcquired_thenUnavailableStatePublishesWithoutEvents() async throws {
        let fixture = try EventFixture()
        defer { fixture.remove() }
        let environment = fixture.environment()
        let error = WireEnvelope.incompatibility("incompatible events")
        let repository = EventStreamRepositoryImpl(toolEnvironment: environment, snapshotRepository: NullTaskSnapshotRepository(),
            scheduler: NullScheduling(), compatibilityCheck: { _ in .failure(error) })
        let lease = repository.acquire(fixture.taskID)
        defer { lease.release() }
        await waitUntil { repository.eventsAvailability(for: fixture.taskID) == .unavailable }
        #expect(repository.events(for: fixture.taskID).isEmpty)
        #expect(repository.history(for: fixture.taskID).error == error.message)
    }

    @Test func givenSummaryCompatibilityFails_whenTheLeaseIsAcquired_thenUnavailableStatePublishesWithoutEvents() async throws {
        let fixture = try EventFixture()
        defer { fixture.remove() }
        let environment = fixture.environment()
        let error = WireEnvelope.incompatibility("incompatible summary")
        let repository = EventStreamRepositoryImpl(toolEnvironment: environment, snapshotRepository: NullTaskSnapshotRepository(),
            scheduler: NullScheduling(), compatibilityCheck: { _ in .failure(error) })
        let lease = repository.acquireSummary(fixture.taskID)
        defer { lease.release() }
        await waitUntil { repository.summary(for: fixture.taskID).availability == .unavailable }
        #expect(repository.events(for: fixture.taskID).isEmpty)
        #expect(repository.history(for: fixture.taskID).error == error.message)
    }

    @Test func givenCtlListingIsOutstanding_whenSettingsChange_thenStaleListingCannotPublishOrStartWatcher() async {
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
        #expect(!sut.watcherActive)
        secondListing.open()
        await waitUntil { sut.tasks.map(\.taskID) == ["current"] }
    }

    @Test func givenInitialCompatibilityFails_whenScheduledRetrySucceeds_thenListingAndWatcherStartOnlyAfterSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HfCompatibility-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scheduler = CapturingScheduler()
        let runner = compatibleRunner { _ in .success(historyOutput(taskID: "recovered")) }
        let checker = LockedBox(0)
        let incompatibility = WireEnvelope.incompatibility("old runtime")
        let environment = taskListEnvironment(runner: runner, tasksDirectory: directory.path)
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
        #expect(!sut.watcherActive)
        await waitUntil { scheduler.oneShotCount(interval: 10) == 1 }
        scheduler.fireFirstOneShot()
        await waitUntil { sut.tasks.map(\.taskID) == ["recovered"] && sut.watcherActive }
        #expect(!runner.calls.isEmpty)
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

    private func drainTasks() async {
        for _ in 0 ..< 8 { await Task.yield() }
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

private final class QueueBlocker: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCompletion: (@Sendable () -> Void)?
    private var completedValue = false
    private var released = false

    var completion: (@Sendable () -> Void)? {
        get { lock.withLock { storedCompletion } }
        set {
            let completion = lock.withLock { () -> (@Sendable () -> Void)? in
                storedCompletion = newValue
                return released ? storedCompletion : nil
            }
            completion?()
        }
    }

    var completed: Bool {
        get { lock.withLock { completedValue } }
        set { lock.withLock { completedValue = newValue } }
    }

    func release() {
        let completion = lock.withLock { () -> (@Sendable () -> Void)? in
            released = true
            return storedCompletion
        }
        completion?()
    }
}

private struct EventFixture {
    let directory: URL
    let taskID = "lifecycle"
    let tasksDirectory: URL

    init() throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("HfLifecycle-\(UUID())")
        self.tasksDirectory = directory.appendingPathComponent("tasks")
        try FileManager.default.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)
        let line = currentEventFixture(#"{"v":1,"seq":1,"kind":"notice","text":"fixture"}"#) + "\n"
        try line.write(
            to: tasksDirectory.appendingPathComponent("\(taskID).events.jsonl"), atomically: true, encoding: .utf8)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func environment() -> MockToolEnvironmentRepository {
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(tasksDirectory.path)
        return environment
    }
}
