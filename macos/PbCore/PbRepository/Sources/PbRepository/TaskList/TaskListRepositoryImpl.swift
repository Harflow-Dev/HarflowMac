import Combine
import Foundation
import MonitorCore
import PbUtilities

// MARK: - TaskListRepositoryImpl

public final class TaskListRepositoryImpl: TaskListRepository, @unchecked Sendable {

    private let toolEnvironment: any ToolEnvironmentRepository
    private let snapshotRepository: any TaskSnapshotRepository
    private let eventStreamRepository: any EventStreamRepository
    private let finishNotifier: any FinishNotifier
    private let scheduler: any Scheduling

    @Subjected private var tasksValue: [TaskInfo] = []
    @Subjected private var listErrorValue: ToolError?
    @Subjected private var hasListedValue = false
    @Subjected private var titlesValue: [String: String] = [:]

    private let titlesLock = NSLock()
    private let startLock = NSLock()
    private var started = false

    private let watcherLock = NSLock()
    private var watcher: DirectoryWatcher?
    private var pollToken: AnyCancellable?

    private let refreshCoordinator = RefreshCoordinator()
    private let throttleLock = NSLock()
    private var pendingRefreshToken: AnyCancellable?

    private let lastRefreshLock = NSLock()
    private var lastRefreshValue: Date = .distantPast

    /// `lastRefresh` is written from `runOneRefresh()` (reached from `refresh()`, itself called from
    /// several independent contexts: `start()`'s Task, the throttled-refresh Task, the poll Task,
    /// `settingsChanged()`) and read from the poll closure's reconcile check, which runs on
    /// `Scheduling`'s own queue — a different thread than any of the writers. A plain stored `var`
    /// here is a genuine data race the Swift 6 compiler does not catch (this type is
    /// `@unchecked Sendable`); a lock-backed computed property closes it the same way `watcher` and
    /// `titlesValue`'s merge already are.
    private var lastRefresh: Date {
        get { lastRefreshLock.lock(); defer { lastRefreshLock.unlock() }; return lastRefreshValue }
        set { lastRefreshLock.lock(); defer { lastRefreshLock.unlock() }; lastRefreshValue = newValue }
    }

    public init(
        toolEnvironment: any ToolEnvironmentRepository,
        snapshotRepository: any TaskSnapshotRepository,
        eventStreamRepository: any EventStreamRepository,
        finishNotifier: any FinishNotifier,
        scheduler: any Scheduling
    ) {
        self.toolEnvironment = toolEnvironment
        self.snapshotRepository = snapshotRepository
        self.eventStreamRepository = eventStreamRepository
        self.finishNotifier = finishNotifier
        self.scheduler = scheduler
    }

    // MARK: Published state

    public var tasks: [TaskInfo] { tasksValue }
    public var listError: ToolError? { listErrorValue }
    public var hasListed: Bool { hasListedValue }
    public var titles: [String: String] { titlesValue }

    public func tasksPublisher() -> AnyPublisher<[TaskInfo], Never> { $tasksValue.eraseToAnyPublisher() }
    public func listErrorPublisher() -> AnyPublisher<ToolError?, Never> { $listErrorValue.eraseToAnyPublisher() }
    public func hasListedPublisher() -> AnyPublisher<Bool, Never> { $hasListedValue.eraseToAnyPublisher() }
    public func titlesPublisher() -> AnyPublisher<[String: String], Never> { $titlesValue.eraseToAnyPublisher() }

    // MARK: Startup (MS-LIST-1/F4-01)

    public func start() {
        startLock.lock()
        guard !started else { startLock.unlock(); return }
        started = true
        startLock.unlock()
        Task {
            await toolEnvironment.discoverEnvironment()
            await refresh()
            startWatching()
        }
    }

    private func startWatching() {
        let watcher = DirectoryWatcher(path: toolEnvironment.tasksDirectory) { [weak self] names in
            guard names.contains(where: RefreshTrigger.isRelevant) else { return }
            self?.scheduleThrottledRefresh()
        }
        watcher.start()
        // A dead owner writes nothing, and the tasks folder may not exist yet: a 10 s safety poll
        // while that matters, and an unconditional reconcile every minute regardless (F4-06).
        let token = scheduler.scheduleRepeating(every: 10) { [weak self] in
            guard let self else { return }
            Task {
                let due = self.scheduler.now().timeIntervalSince(self.lastRefresh) >= RefreshTrigger.reconcileInterval
                if due || self.tasksValue.contains(where: \.status.isRunning) || self.listErrorValue != nil || !self.watcherActive {
                    await self.refresh()
                }
            }
        }
        // `watcher` and `pollToken` are set together, under the same lock that guards every other
        // read of `watcher` (`watcherActive`, `restartWatcherIfInactive`) — `pollToken` is written
        // only here, but `startWatching()` runs on whatever thread `start()`'s Task resumes on,
        // which is not guaranteed to be the same thread across calls, so the write still needs the
        // lock for correct publication to any later reader.
        watcherLock.lock()
        self.watcher = watcher
        pollToken = token
        watcherLock.unlock()
    }

    private var watcherActive: Bool {
        watcherLock.lock(); defer { watcherLock.unlock() }
        return watcher?.isActive ?? false
    }

    // MARK: Throttled refresh (MS-LIST-2/F4-07: leading-arm, fixed-delay — never a debounce)

    private func scheduleThrottledRefresh() {
        throttleLock.lock()
        guard pendingRefreshToken == nil else { throttleLock.unlock(); return }
        let token = scheduler.schedule(after: 1) { [weak self] in
            guard let self else { return }
            throttleLock.lock()
            pendingRefreshToken = nil
            throttleLock.unlock()
            Task { await self.refresh() }
        }
        pendingRefreshToken = token
        throttleLock.unlock()
    }

    public func settingsChanged() {
        Task { await refresh() }
    }

    // MARK: Refresh (MS-LIST-4/F4-08/F4-09)

    public func refresh() async {
        guard await refreshCoordinator.begin() else { return }
        repeat {
            await runOneRefresh()
        } while await refreshCoordinator.consumeAgainAndDecideContinue()
        restartWatcherIfInactive()
    }

    /// A synchronous helper so the lock is never taken directly inside an `async` function body
    /// (Swift 6 forbids that — "use async-safe scoped locking instead").
    private func restartWatcherIfInactive() {
        watcherLock.lock()
        defer { watcherLock.unlock() }
        if watcher?.isActive != true { watcher?.start() }
    }

    private func runOneRefresh() async {
        let result: Result<[TaskInfo], ToolError> = switch toolEnvironment.ctl() {
        case .failure(let error): .failure(error)
        case .success(let client): await client.list()
        }
        switch result {
        case .success(let listed):
            let previous = tasksValue
            tasksValue = listed
            listErrorValue = nil
            lastRefresh = scheduler.now()
            // A task that left the listing (retention) must not live on in the detail cache.
            let listedIDs = Set(listed.map(\.taskID))
            snapshotRepository.evict(keeping: listedIDs)
            if hasListedValue {
                let finished = Lineage.finishedRoots(previous: previous, current: listed)
                finishNotifier.notify(finished) { [weak self] id in self?.title(id) ?? "Task \(id.prefix(8))" }
            }
            hasListedValue = true
            loadTitles()
            for id in eventStreamRepository.leasedTaskIDs { await snapshotRepository.refresh(id) }
        case .failure(let error):
            listErrorValue = error
        }
    }

    // MARK: Titles (MS-LIST-5/F4-11)

    private func loadTitles() {
        let missing = tasksValue.map(\.taskID).filter { titlesValue[$0] == nil }
        guard !missing.isEmpty else { return }
        let dir = toolEnvironment.tasksDirectory
        Task.detached(priority: .utility) { [weak self] in
            var found: [String: String] = [:]
            for id in missing.prefix(500) {
                guard let path = TaskTitle.eventsPath(tasksDirectory: dir, taskID: id),
                      let prompt = TaskTitle.firstPrompt(eventsPath: path),
                      let title = TaskTitle.from(prompt: prompt) else { continue }
                found[id] = title
            }
            guard let self else { return }
            mergeTitles(found)
        }
    }

    /// A synchronous helper so the lock is never taken directly inside an `async` context.
    private func mergeTitles(_ found: [String: String]) {
        titlesLock.lock()
        defer { titlesLock.unlock() }
        var current = titlesValue
        current.merge(found) { old, _ in old }
        titlesValue = current
    }

    public func title(_ taskID: String) -> String {
        titlesValue[taskID] ?? "Task \(taskID.prefix(8))"
    }

    // MARK: Lookups (MS-LIST-6, the C.8 fix)

    public func task(_ id: String) -> TaskInfo? {
        tasksValue.first { $0.taskID == id }
    }

    public func detail(_ id: String) -> TaskInfo? {
        if hasListedValue, task(id) == nil { return nil }
        if let snapshot = snapshotRepository.snapshot(id), let listed = task(id), listed.status != snapshot.status {
            return listed
        }
        return snapshotRepository.snapshot(id) ?? task(id)
    }

    public func runningInSubtrees(of ids: [String]) -> [String] {
        var result: [String] = []
        var frontier = ids
        var seen = Set<String>()
        while let id = frontier.popLast() {
            guard seen.insert(id).inserted else { continue }
            if task(id)?.status.isRunning == true { result.append(id) }
            frontier.append(contentsOf: Lineage.children(of: id, in: tasksValue).map(\.taskID))
        }
        return result
    }

    public var runningCount: Int { tasksValue.filter(\.status.isRunning).count }

    // MARK: Connection line (MS-LIST-7/F4-26)

    public var connectionLine: String {
        if let listErrorValue {
            if case .notFound = listErrorValue { return "polybridge-ctl not found" }
            return "polybridge not readable"
        }
        let backends = Set(tasksValue.map(\.backend)).sorted()
        return hasListedValue ? "polybridge connected" + (backends.isEmpty ? "" : " · " + backends.joined(separator: ", ")) : "connecting…"
    }
}

// MARK: - RefreshCoordinator

/// The `refreshing`/`refreshAgain` coalescing pair from `AppModel.refresh` (`AppModel.swift:139-167`),
/// as a private actor so the check-and-set is atomic without a manual lock (decision 12: async
/// mutable state lives in a private actor).
private actor RefreshCoordinator {
    private var refreshing = false
    private var again = false

    /// Returns `true` if the caller should run a refresh round now; `false` if one was already in
    /// flight (in which case another pass is armed instead — MS-LIST-4).
    func begin() -> Bool {
        if refreshing { again = true; return false }
        refreshing = true
        return true
    }

    /// Called after one refresh round. Clears the "again" flag and reports whether the caller should
    /// loop for one more round; ends the refreshing state when it will not.
    func consumeAgainAndDecideContinue() -> Bool {
        if again {
            again = false
            return true
        }
        refreshing = false
        return false
    }
}
