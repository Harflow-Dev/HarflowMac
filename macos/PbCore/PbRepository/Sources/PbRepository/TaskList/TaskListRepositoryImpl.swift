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

    // Test seams (internal, not public API): each counts completed passes of an otherwise
    // fire-and-forget background unit, so a test can await one deterministically instead of a fixed
    // sleep that races a slow CI runner. See `mergeTitles(_:)` and `startWatching()`'s poll closure,
    // their only writers.
    @Subjected private(set) var titleLoadPassCount = 0
    @Subjected private(set) var safetyPollEvaluationCount = 0
    /// Calls that joined a pass already in flight instead of starting one — counted only after the
    /// coordinator has registered them, so a test waiting on it knows they are queued.
    @Subjected private(set) var coalescedCallCount = 0

    private let safetyPollCountLock = NSLock()
    private let titlesLock = NSLock()
    private var failedTitleIDs: Set<String> = []
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
            _ = await toolEnvironment.discoverEnvironment()
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
                self.countSafetyPollEvaluation()
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
        guard await refreshCoordinator.begin() else {
            countCoalescedCall()
            return
        }
        _ = await runRefreshLoop()
    }

    /// R2-3: unlike `refresh()`, this waits for — and returns — the result of a pass that starts
    /// **after** this call, never a stale one already in flight when it was called. See
    /// `RefreshCoordinator.registerWaiter(_:)` for the atomic register-and-arm this relies on.
    public func refreshAndWait() async -> Result<Void, ToolError> {
        // Even the caller that starts the loop is only a waiter on its first pass: the loop itself
        // runs detached, so passes armed by later polls never hold this barrier open.
        await withCheckedContinuation { continuation in
            Task {
                if await refreshCoordinator.registerWaiter(continuation) {
                    _ = await runRefreshLoop()
                } else {
                    countCoalescedCall()
                }
            }
        }
    }

    /// Runs the coalescing loop to settling. Only ever called by whichever caller claimed the run
    /// (`begin()` or `registerWaiter(_:)` returning "start it") — every other concurrent caller
    /// either returns immediately (`refresh()`) or is resolved as a waiter by the pass it is owed.
    /// Returns the loop's first pass's result.
    private func runRefreshLoop() async -> Result<Void, ToolError> {
        var firstResult: Result<Void, ToolError>?
        repeat {
            let owed = await refreshCoordinator.beginPass()
            let result = await runOneRefresh()
            if firstResult == nil { firstResult = result }
            let continueLoop = await refreshCoordinator.endPass(owed: owed, result: result)
            if !continueLoop { break }
        } while true
        restartWatcherIfInactive()
        return firstResult ?? .success(())
    }

    /// A synchronous helper so the lock is never taken directly inside an `async` function body
    /// (Swift 6 forbids that — "use async-safe scoped locking instead").
    private func restartWatcherIfInactive() {
        watcherLock.lock()
        defer { watcherLock.unlock() }
        if watcher?.isActive != true { watcher?.start() }
    }

    /// Returns the outcome of this one pass — used by `refreshAndWait()`'s completion barrier, so a
    /// caller waiting on it sees the same success/failure the listing itself just recorded.
    @discardableResult
    private func runOneRefresh() async -> Result<Void, ToolError> {
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
            // Before notifications: their title closure must already see an explicit title.
            seedExplicitTitles(from: listed)
            if hasListedValue {
                let finished = Lineage.finishedRoots(previous: previous, current: listed)
                finishNotifier.notify(finished) { [weak self] id in self?.title(id) ?? "Task \(id.prefix(8))" }
            }
            hasListedValue = true
            loadTitles()
            for id in eventStreamRepository.leasedTaskIDs { await snapshotRepository.refresh(id) }
            return .success(())
        case .failure(let error):
            listErrorValue = error
            return .failure(error)
        }
    }

    // MARK: Titles (MS-LIST-5/F4-11)

    private func loadTitles() {
        let failed = failedTitleIDsSnapshot()
        let untitled = tasksValue.map(\.taskID).filter { titlesValue[$0] == nil }
        // Never-tried ids go first and earlier failures after them, so the capped pass can't keep
        // re-reading the same unresolvable head while later tasks wait, yet a failure that was only
        // transient is still retried whenever the cap leaves room.
        let missing = untitled.filter { !failed.contains($0) } + untitled.filter { failed.contains($0) }
        guard !missing.isEmpty else { return }
        let settled = Set(tasksValue.filter(\.status.isTerminal).map(\.taskID))
        let dir = toolEnvironment.tasksDirectory
        Task.detached(priority: .utility) { [weak self] in
            var found: [String: String] = [:]
            var failedSettled: Set<String> = []
            for id in missing.prefix(500) {
                guard let path = TaskTitle.eventsPath(tasksDirectory: dir, taskID: id),
                      let prompt = TaskTitle.firstPrompt(eventsPath: path),
                      let title = TaskTitle.from(prompt: prompt) else {
                    if settled.contains(id) { failedSettled.insert(id) }
                    continue
                }
                found[id] = title
            }
            guard let self else { return }
            mergeTitles(found, failed: failedSettled)
        }
    }

    /// A task started with an explicit `title` carries it in the listing. It replaces any
    /// prompt-derived entry for that id (unlike `mergeTitles`, where the existing value wins), and
    /// being present before `loadTitles()` runs it also keeps those ids out of the event-log reads.
    /// A synchronous helper so the lock is never taken directly inside an `async` context.
    private func seedExplicitTitles(from listed: [TaskInfo]) {
        var explicit: [String: String] = [:]
        for task in listed {
            guard let title = task.raw["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { continue }
            explicit[task.taskID] = title
        }
        guard !explicit.isEmpty else { return }
        titlesLock.lock()
        defer { titlesLock.unlock() }
        var current = titlesValue
        current.merge(explicit) { _, explicit in explicit }
        if current != titlesValue { titlesValue = current }
    }

    private func failedTitleIDsSnapshot() -> Set<String> {
        titlesLock.lock()
        defer { titlesLock.unlock() }
        return failedTitleIDs
    }

    /// A synchronous helper so the lock is never taken directly inside an `async` context.
    ///
    /// `failed` holds settled tasks whose title could not be read (a legacy task, a missing or
    /// unreadable log, no `task_started`). Left at the head of every capped pass they would starve
    /// every task after them (Codex PR review), so `loadTitles` queues them behind never-tried ids.
    /// A running task is never marked — its first event may simply not be written yet.
    func mergeTitles(_ found: [String: String], failed: Set<String>) {
        titlesLock.lock()
        defer { titlesLock.unlock() }
        var current = titlesValue
        current.merge(found) { old, _ in old }
        titlesValue = current
        failedTitleIDs.formUnion(failed)
        failedTitleIDs.subtract(found.keys)
        titleLoadPassCount += 1
    }

    /// Overlapping poll `Task`s can finish together; `@Subjected` locks its getter and setter
    /// separately, so the read-modify-write needs a lock of its own or a count is lost.
    private func countCoalescedCall() {
        safetyPollCountLock.lock()
        defer { safetyPollCountLock.unlock() }
        coalescedCallCount += 1
    }

    private func countSafetyPollEvaluation() {
        safetyPollCountLock.lock()
        defer { safetyPollCountLock.unlock() }
        safetyPollEvaluationCount += 1
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
/// mutable state lives in a private actor). Extended for R2-3 (`refreshAndWait()`) with a second,
/// waiter-based entry: `begin()` stays exactly `refresh()`'s original fire-and-forget coalescing
/// (a coalesced caller just returns without waiting), while `registerWaiter(_:)` additionally
/// registers a continuation so its caller is resolved once a **specific** pass — one that starts
/// after its own registration — completes, without waiting for the whole coalescing chain to go
/// idle. `beginPass()`/`endPass(owed:result:)` are what make that per-registration promise hold:
/// each iteration only ever owes a result to whoever registered *before that iteration started*,
/// never to someone who registers while it is running (they land in the next iteration's batch).
private actor RefreshCoordinator {
    private var refreshing = false
    private var again = false
    private var pendingWaiters: [CheckedContinuation<Result<Void, ToolError>, Never>] = []

    /// Returns `true` if the caller should run a refresh round now; `false` if one was already in
    /// flight (in which case another pass is armed instead — MS-LIST-4). Unchanged from before
    /// `refreshAndWait()` existed: a coalesced `refresh()` caller never waits.
    func begin() -> Bool {
        if refreshing { again = true; return false }
        refreshing = true
        return true
    }

    /// `refreshAndWait()`'s entry: one atomic actor call that registers the waiter and arms a pass
    /// for it — so no pass can complete in the gap between "a run is in flight" and "I'm registered
    /// for the next one." Returns `true` when nothing was in flight, so the caller must start the
    /// loop (whose first pass then owes this waiter its result).
    func registerWaiter(_ continuation: CheckedContinuation<Result<Void, ToolError>, Never>) -> Bool {
        pendingWaiters.append(continuation)
        if refreshing {
            again = true
            return false
        }
        refreshing = true
        return true
    }

    /// One iteration boundary: hands back every waiter registered *before* this pass starts — it
    /// now owes them its result — and clears `again`, so a fire-and-forget `begin()` call that
    /// arrived before this point is also satisfied by this very pass.
    func beginPass() -> [CheckedContinuation<Result<Void, ToolError>, Never>] {
        again = false
        let owed = pendingWaiters
        pendingWaiters = []
        return owed
    }

    /// Resolves everyone this pass owed, then reports whether another iteration is needed — true
    /// when `again` was (re-)armed, or a new waiter registered, while this pass was running.
    func endPass(owed: [CheckedContinuation<Result<Void, ToolError>, Never>], result: Result<Void, ToolError>) -> Bool {
        for continuation in owed { continuation.resume(returning: result) }
        if again || !pendingWaiters.isEmpty { return true }
        refreshing = false
        return false
    }
}
