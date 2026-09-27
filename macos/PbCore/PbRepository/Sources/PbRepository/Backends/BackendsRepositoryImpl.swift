import Combine
import Foundation
import MonitorCore
import PbUtilities

// MARK: - BackendsRepositoryImpl

/// Fetches `polybridge-ctl backends` at the refresh points Review round 1 item 1 settled on: startup
/// (after tool discovery), a tool-directory change (`settingsChanged()`), a successful
/// install/update (observed via `InstallRepository.statePublisher()` reaching `.installed`), a
/// bounded app-activation cadence (`appDidBecomeActive()`, at most once per 60 s), and an explicit
/// `refresh()`. Every trigger funnels into the same coalescing loop `TaskListRepositoryImpl` already
/// uses, so no two fetches ever run concurrently — which is what makes "a result from an older
/// environment never overwrites a newer one" hold with no separate generation counter: only one
/// `runOneRefresh()` is ever in flight, and every other caller either returns immediately (coalesced
/// into "run once more") or is a plain fire-and-forget.
public final class BackendsRepositoryImpl: BackendsRepository, @unchecked Sendable {

    private let toolEnvironment: any ToolEnvironmentRepository
    private let installRepository: any InstallRepository
    private let scheduler: any Scheduling

    @Subjected private var catalogValue: BackendCatalog = .empty

    private let startLock = NSLock()
    private var started = false

    /// Code review round 1, finding 3: while `start()` has been called but its own initial
    /// `discoverEnvironment()` hasn't finished yet, `ToolEnvironmentRepository.ctl()` still resolves
    /// against the base (non-login) `PATH` — a fetch run against it would read a login-PATH-only
    /// agent as not installed. `settingsChanged()`/`appDidBecomeActive()` are no-ops until this
    /// flips true; `start()`'s own follow-up `refresh()` (run right after this flips) is what
    /// actually covers them.
    private let discoveryGateLock = NSLock()
    private var initialDiscoveryComplete = false

    private let refreshCoordinator = RefreshCoordinator()

    private let activationLock = NSLock()
    private var lastActivationRefresh: Date = .distantPast

    private let cancellablesLock = NSLock()
    private var cancellables = Set<AnyCancellable>()

    /// Code review round 1, finding 2: bumped by `settingsChanged()` and by an observed install
    /// success — never by `appDidBecomeActive()`'s own throttle, which changes no environment. A
    /// pass records this at its own start and only publishes if it is still current when its
    /// (awaited) fetch returns; a stale pass is simply dropped, since a fresher one is already
    /// queued by the coalescer (`RefreshCoordinator`'s `again` flag). The lock is recursive: the
    /// publish happens while holding it, and a subscriber that synchronously triggers
    /// `settingsChanged()` must not deadlock.
    private let generationLock = NSRecursiveLock()
    private var generationValue = 0

    public init(
        toolEnvironment: any ToolEnvironmentRepository,
        installRepository: any InstallRepository,
        scheduler: any Scheduling
    ) {
        self.toolEnvironment = toolEnvironment
        self.installRepository = installRepository
        self.scheduler = scheduler
    }

    // MARK: Published state

    public var catalog: BackendCatalog { catalogValue }
    public func catalogPublisher() -> AnyPublisher<BackendCatalog, Never> { $catalogValue.eraseToAnyPublisher() }

    // MARK: Startup

    public func start() {
        startLock.lock()
        guard !started else { startLock.unlock(); return }
        started = true
        startLock.unlock()
        subscribeToInstallState()
        Task {
            _ = await toolEnvironment.discoverEnvironment()
            markInitialDiscoveryComplete()
            await refresh()
        }
    }

    /// "After a successful polybridge install/update" (Review round 1 item 1): a fresh refresh every
    /// time the install pipeline reaches its terminal success state, without this repository needing
    /// to be threaded through `InstallRepositoryImpl`'s own barrier. The environment itself may have
    /// changed (a new install can land on a `PATH` this process didn't have before), so this bumps
    /// the generation exactly like `settingsChanged()` (finding 2).
    private func subscribeToInstallState() {
        let token = installRepository.statePublisher()
            .sink { [weak self] state in
                guard case .installed = state else { return }
                guard let self, !isBlockedByPendingInitialDiscovery else { return }
                _ = bumpGeneration()
                Task { await self.refresh() }
            }
        cancellablesLock.lock()
        cancellables.insert(token)
        cancellablesLock.unlock()
    }

    /// A no-op while `start()`'s own initial discovery is still pending (finding 3) — that fetch
    /// would run against the base `PATH`, not the login one, and falsely read a login-PATH-only
    /// agent as not installed; `start()`'s own follow-up `refresh()` already covers this trigger.
    public func settingsChanged() {
        guard !isBlockedByPendingInitialDiscovery else { return }
        _ = bumpGeneration()
        Task { await refresh() }
    }

    /// Bounded to at most once per 60 s (Review round 1 item 1) — the lock only ever guards a plain
    /// timestamp compare-and-set, so it stays synchronous and cheap to call from the app shell. Also
    /// a no-op while `start()`'s own initial discovery is still pending, for the same reason
    /// `settingsChanged()` is (finding 3) — never bumps the generation, since app activation changes
    /// no environment of its own.
    public func appDidBecomeActive() {
        guard !isBlockedByPendingInitialDiscovery else { return }
        activationLock.lock()
        let now = scheduler.now()
        let due = now.timeIntervalSince(lastActivationRefresh) >= 60
        if due { lastActivationRefresh = now }
        activationLock.unlock()
        guard due else { return }
        Task { await refresh() }
    }

    // MARK: Initial-discovery gate (finding 3)

    private func markInitialDiscoveryComplete() {
        discoveryGateLock.lock()
        initialDiscoveryComplete = true
        discoveryGateLock.unlock()
    }

    private var isBlockedByPendingInitialDiscovery: Bool {
        startLock.lock()
        let hasStarted = started
        startLock.unlock()
        guard hasStarted else { return false }
        discoveryGateLock.lock()
        defer { discoveryGateLock.unlock() }
        return !initialDiscoveryComplete
    }

    // MARK: Generation guard (finding 2)

    @discardableResult
    private func bumpGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        generationValue += 1
        return generationValue
    }

    private func currentGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generationValue
    }

    // MARK: Refresh

    public func refresh() async {
        guard await refreshCoordinator.begin() else { return }
        await runRefreshLoop()
    }

    private func runRefreshLoop() async {
        repeat {
            await refreshCoordinator.beginPass()
            await runOneRefresh()
            let continueLoop = await refreshCoordinator.endPass()
            if !continueLoop { break }
        } while true
    }

    /// A failure of any kind — `ctl` not located, an unsupported/malformed/timed-out answer, an
    /// unsupported contract version — degrades rather than errors: it keeps the last successfully
    /// reported names (if any), each downgraded to an unknown install state, per Review round 1
    /// item 2. Never hardcodes a backend name — an empty degraded catalog carries no fallback names
    /// of its own; that fallback (Design's New Session section) lives in the UI layer, which already
    /// has a UI-only display list (`PbUI.BackendStyle.known`) to fall back to.
    ///
    /// **Generation guard (finding 2).** The generation is recorded *before* the awaited fetch, and
    /// checked again right after it returns: if `settingsChanged()`/an install success bumped it
    /// while this pass was in flight, the environment this pass fetched against is already stale, so
    /// its result is dropped unpublished rather than briefly overwriting the catalog with an answer
    /// from an environment that no longer applies — the coalescer (`RefreshCoordinator`'s `again`
    /// flag) already guarantees a fresh pass runs next.
    private func runOneRefresh() async {
        let generationAtStart = currentGeneration()
        let result: Result<[BackendAvailability], ToolError> = switch toolEnvironment.ctl() {
        case .failure(let error): .failure(error)
        case .success(let client): await client.backends()
        }
        publishIfCurrent(result, generation: generationAtStart)
    }

    /// Check and publish under the same lock `bumpGeneration()` takes, so an invalidation can't land
    /// between the check and the assignment. Synchronous so the lock is never held across a suspension.
    private func publishIfCurrent(_ result: Result<[BackendAvailability], ToolError>, generation generationAtStart: Int) {
        generationLock.lock()
        defer { generationLock.unlock() }
        guard generationValue == generationAtStart else { return }
        switch result {
        case .success(let items):
            catalogValue = BackendCatalog(
                entries: items.map { BackendCatalogEntry(backend: $0.backend, installed: $0.installed) },
                state: .available
            )
        case .failure:
            let carried = catalogValue.entries.map { BackendCatalogEntry(backend: $0.backend, installed: nil) }
            catalogValue = BackendCatalog(entries: carried, state: .degraded)
        }
    }
}

// MARK: - RefreshCoordinator

/// The same fire-and-forget coalescing pair as `TaskListRepositoryImpl.RefreshCoordinator`
/// (`begin()`/`beginPass()`/`endPass(owed:)`), trimmed to the subset this repository needs — nothing
/// here awaits a specific pass's result the way `TaskListRepository.refreshAndWait()` does, so there
/// is no waiter list to carry.
private actor RefreshCoordinator {
    private var refreshing = false
    private var again = false

    func begin() -> Bool {
        if refreshing { again = true; return false }
        refreshing = true
        return true
    }

    /// Clears `again` at the start of a pass, so a fire-and-forget `begin()` call that arrived
    /// before this point is satisfied by this very pass.
    func beginPass() { again = false }

    /// Reports whether another iteration is needed — true when `again` was (re-)armed while this
    /// pass was running.
    func endPass() -> Bool {
        if again { return true }
        refreshing = false
        return false
    }
}
