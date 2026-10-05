import Combine
import Foundation
import MonitorCore
import PbUtilities

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

    // Test seams count completed background passes so tests can await completion instead of sleeping.
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

    @Subjected private var historyStateValue = HistoryLoadingState()
    private let historyLock = NSRecursiveLock()
    private var historyTasks: [String: TaskInfo] = [:]
    private var relatedTasks: [String: TaskInfo] = [:]
    private var totalActiveCount = 0
    private var notificationBaseline: [TaskInfo]?
    private var loadingMore = false
    private var historyInitialized = false
    private var historyRefreshFailed = false
    private var activeRefreshOffset = 0
    private var terminalRefreshOffset = 0
    private var snapshotRefreshOffset = 0

    private let refreshCoordinator = RefreshCoordinator()
    private let throttleLock = NSLock()
    private var pendingRefreshToken: AnyCancellable?

    private let lastRefreshLock = NSLock()
    private var lastRefreshValue: Date = .distantPast

    /// Refresh tasks and the safety-poll queue share this timestamp under a lock.
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
                let requiresReconciliation = self.tasksValue.contains {
                    $0.status.isRunning || $0.raw["needs_reconciliation"]?.boolValue == true
                }
                if due || requiresReconciliation || self.historyStateValue.bootstrapPending || self.listErrorValue != nil || !self.watcherActive {
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
        let result: Result<[TaskInfo], ToolError>
        switch toolEnvironment.ctl() {
        case .failure(let error): result = .failure(error)
        case .success(let client):
            let first = await client.taskHistoryPage()
            switch first {
            case .failure(let error): result = .failure(error)
            case .success(let page):
                do {
                    let activePage = try await client.taskHistoryPage(activeOnly: true).get()
                    let visible = Set(page.items.map(\.taskID) + activePage.items.map(\.taskID))
                    let stale = nextActiveRefreshBatch(excluding: visible)
                    let updates = stale.isEmpty ? nil : try await client.taskHistoryPage(taskIDs: stale).get()
                    let terminalIDs = nextTerminalRefreshBatch(excluding: visible)
                    let terminalPage = terminalIDs.isEmpty ? nil : try await client.taskHistoryPage(taskIDs: terminalIDs).get()
                    result = .success(mergeHistory(page, active: activePage, updates: updates,
                                                  terminalPage: terminalPage, terminalIDs: terminalIDs))
                } catch {
                    result = .failure(error as? ToolError ?? .unreadable(tool: "polybridge-ctl", exitCode: 0, stderr: String(describing: error)))
                }
            }
        }
        switch result {
        case .success(let listed):
            publishHistory()
            listErrorValue = nil
            historyLock.withLock {
                if historyRefreshFailed { historyStateValue.error = nil }
                historyRefreshFailed = false
            }
            lastRefresh = scheduler.now()
            // A task that left the listing (retention) must not live on in the detail cache.
            let listedIDs = Set(listed.map(\.taskID))
            snapshotRepository.evict(keeping: listedIDs.union(eventStreamRepository.leasedTaskIDs).union(historyLock.withLock { Set(relatedTasks.keys) }))
            // Before notifications: their title closure must already see an explicit title.
            seedExplicitTitles(from: listed)
            if !historyStateValue.bootstrapPending { updateNotificationBaseline(listed) }
            hasListedValue = true
            // Catalog titles are bounded summaries; row population never scans event logs.
            for id in nextSnapshotRefreshBatch() { await snapshotRepository.refresh(id) }
            return .success(())
        case .failure(let error):
            listErrorValue = error
            historyLock.withLock {
                historyRefreshFailed = true
                historyStateValue.error = error
            }
            return .failure(error)
        }
    }

    public var historyState: HistoryLoadingState { historyStateValue }
    public func historyStatePublisher() -> AnyPublisher<HistoryLoadingState, Never> { $historyStateValue.eraseToAnyPublisher() }

    private func mergeHistory(_ page: TaskHistoryPage, active: TaskHistoryPage? = nil, updates: TaskHistoryPage? = nil,
                              terminalPage: TaskHistoryPage? = nil, terminalIDs: [String] = [], advancing: Bool = false) -> [TaskInfo] {
        historyLock.withLock {
            pruneTerminalHistory(terminalPage, ids: terminalIDs)
            for task in page.items + page.relatedItems + (active?.items ?? []) + (active?.relatedItems ?? [])
                + (updates?.items ?? []) + (updates?.relatedItems ?? []) { historyTasks[task.taskID] = task }
            for task in (terminalPage?.items ?? []) + (terminalPage?.relatedItems ?? []) {
                let current = [historyTasks[task.taskID], relatedTasks[task.taskID]].compactMap(\.self)
                guard !current.contains(where: { $0.status.isRunning || $0.raw["needs_reconciliation"]?.boolValue == true }) else { continue }
                if historyTasks[task.taskID] != nil { historyTasks[task.taskID] = task }
                if relatedTasks[task.taskID] != nil { relatedTasks[task.taskID] = task }
            }
            let countPage = active?.page ?? page.page
            if !advancing, countPage.countsComplete { totalActiveCount = countPage.totalActiveCount }
            var state = historyStateValue
            if advancing || !historyInitialized {
                state.nextCursor = page.page.nextCursor
                state.hasMore = page.page.hasMore
            }
            if !page.page.bootstrapPending { historyInitialized = true }
            state.bootstrapPending = page.page.bootstrapPending || (active?.page.bootstrapPending ?? false)
            state.historyIncomplete = page.page.historyIncomplete
            state.authorityIncomplete = page.page.authorityIncomplete
            if !advancing { state.countsComplete = countPage.countsComplete && !page.page.bootstrapPending }
            if advancing { state.error = nil }
            historyStateValue = state
            return historyTasks.values.sorted {
                let lhs = $0.startedAt ?? .distantPast
                let rhs = $1.startedAt ?? .distantPast
                return lhs == rhs ? $0.taskID > $1.taskID : lhs > rhs
            }
        }
    }

    private func updateNotificationBaseline(_ listed: [TaskInfo]) {
        func unreconciled(_ task: TaskInfo) -> Bool {
            task.raw["needs_reconciliation"]?.boolValue == true
                && task.raw["observed_exit"]?.boolValue != true
                && task.raw["status_reconciled"]?.boolValue != true
        }
        let previous = Dictionary((notificationBaseline ?? []).map { ($0.taskID, $0) }, uniquingKeysWith: { _, new in new })
        let observed = listed.map { task in unreconciled(task) ? previous[task.taskID] ?? task : task }
        if let baseline = notificationBaseline {
            let finished = Lineage.finishedRoots(previous: baseline, current: observed).filter { !unreconciled($0) }
            finishNotifier.notify(finished) { [weak self] id in self?.title(id) ?? "Task \(id.prefix(8))" }
        }
        notificationBaseline = observed
    }

    private func nextSnapshotRefreshBatch() -> [String] {
        let leased = eventStreamRepository.leasedTaskIDs.sorted()
        return historyLock.withLock {
            guard !leased.isEmpty else { snapshotRefreshOffset = 0; return [] }
            let offset = snapshotRefreshOffset % leased.count
            let batch = Array((Array(leased[offset...]) + Array(leased[..<offset])).prefix(100))
            snapshotRefreshOffset = (offset + batch.count) % leased.count
            return batch
        }
    }

    private func publishHistory() {
        historyLock.withLock {
            tasksValue = historyTasks.values.sorted {
                let lhs = $0.startedAt ?? .distantPast
                let rhs = $1.startedAt ?? .distantPast
                return lhs == rhs ? $0.taskID > $1.taskID : lhs > rhs
            }
        }
    }

    private func pruneTerminalHistory(_ terminalPage: TaskHistoryPage?, ids terminalIDs: [String]) {
    if let terminalPage, ![terminalPage.page.hasMore, terminalPage.page.bootstrapPending,
                           terminalPage.page.authorityIncomplete, terminalPage.page.historyIncomplete].contains(true) {
        let present = Set(terminalPage.items.map(\.taskID))
        for id in terminalIDs where !present.contains(id) {
            // A concurrent explicit resolution may have promoted this row to active.
            let current = [historyTasks[id], relatedTasks[id]].compactMap(\.self)
            guard !current.isEmpty, current.allSatisfy({ !$0.status.isRunning && $0.raw["needs_reconciliation"]?.boolValue != true }) else { continue }
            historyTasks.removeValue(forKey: id)
            relatedTasks.removeValue(forKey: id)
        }
    }
    }

    private func nextTerminalRefreshBatch(excluding ids: Set<String>) -> [String] {
        historyLock.withLock {
            let inventory = historyTasks.merging(relatedTasks) { history, related in
                history.status.isRunning || history.raw["needs_reconciliation"]?.boolValue == true ? history : related
            }
            let terminal = inventory.values
.filter {
                !$0.status.isRunning && $0.raw["needs_reconciliation"]?.boolValue != true && !ids.contains($0.taskID)
            }
.map(\.taskID)
.sorted()
            guard !terminal.isEmpty else { terminalRefreshOffset = 0; return [] }
            let offset = terminalRefreshOffset % terminal.count
            let batch = Array((Array(terminal[offset...]) + Array(terminal[..<offset])).prefix(100))
            terminalRefreshOffset = (offset + batch.count) % terminal.count
            return batch
        }
    }

    private func nextActiveRefreshBatch(excluding ids: Set<String>) -> [String] {
        historyLock.withLock {
            let active = historyTasks.values
.filter {
                ($0.status.isRunning || $0.raw["needs_reconciliation"]?.boolValue == true) && !ids.contains($0.taskID)
            }
.map(\.taskID)
.sorted()
            guard !active.isEmpty else { activeRefreshOffset = 0; return [] }
            let offset = activeRefreshOffset % active.count
            let batch = Array((Array(active[offset...]) + Array(active[..<offset])).prefix(100))
            activeRefreshOffset = (offset + batch.count) % active.count
            return batch
        }
    }

    public func loadMoreHistory() async {
        if historyLock.withLock({ historyRefreshFailed || historyStateValue.authorityIncomplete }) {
            await refresh()
            return
        }
        let request = historyLock.withLock { () -> HistoryLoadingState? in
            guard !loadingMore, historyStateValue.hasMore || historyStateValue.bootstrapPending || historyStateValue.error != nil else { return nil }
            loadingMore = true
            var state = historyStateValue
            state.isLoading = true
            state.error = nil
            historyStateValue = state
            return state
        }
        guard let state = request else { return }
        defer {
            historyLock.withLock {
                loadingMore = false
                historyStateValue.isLoading = false
            }
        }
        do {
            let client = try toolEnvironment.ctl().get()
            let page = try await client.taskHistoryPage(cursor: state.nextCursor).get()
            _ = mergeHistory(page, advancing: true)
            publishHistory()
            seedExplicitTitles(from: page.items)
        } catch {
            historyLock.withLock {
                historyStateValue.error = error as? ToolError ?? .unreadable(tool: "polybridge-ctl", exitCode: 0, stderr: String(describing: error))
            }
        }
    }

    public func resolve(_ id: String) async -> TaskInfo? {
        guard let client = try? toolEnvironment.ctl().get() else { return task(id) }
        var current: String? = id
        var visited: Set<String> = []
        var resolved: [TaskInfo] = []
        while let target = current, visited.count < 32, visited.insert(target).inserted {
            let fetched: TaskInfo? = if target != id, let existing = task(target) { existing } else { try? await client.status(target).get() }
            guard let item = fetched else { break }
            resolved.append(item)
            current = item.parentTaskID ?? item.spawnedBy
        }
        historyLock.withLock {
            for item in resolved { historyTasks[item.taskID] = item }
        }
        publishHistory()
        seedExplicitTitles(from: resolved)
        return task(id)
    }

    public func conversationPage(sessionID: String, cursor: String?, limit: Int = 100) async throws -> TaskHistoryPage {
        let client = try toolEnvironment.ctl().get()
        let page = try await client.taskHistoryPage(cursor: cursor, limit: limit, sessionID: sessionID).get()
        historyLock.withLock { for task in page.items + page.relatedItems { relatedTasks[task.taskID] = task } }
        seedExplicitTitles(from: page.items)
        return page
    }

    /// Explicit catalog titles take precedence over prompt-derived titles.
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
        tasksValue.first { $0.taskID == id } ?? historyLock.withLock { relatedTasks[id] }
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

    public var runningCount: Int {
        historyLock.withLock {
            historyStateValue.countsComplete ? max(totalActiveCount, tasksValue.filter(\.status.isRunning).count) : totalActiveCount
        }
    }

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
