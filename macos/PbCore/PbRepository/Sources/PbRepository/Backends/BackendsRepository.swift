import Combine
import Foundation
import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - BackendCatalogState

/// Whether the last `polybridge-ctl backends` fetch actually succeeded. `.degraded` covers every
/// failure mode alike — an older ctl without the command, a malformed payload, a timeout, or an
/// unsupported contract version — none of which is ever surfaced as "not installed" (Monitor piece
/// 6, Review round 1 item 2): a degraded fetch has no fresh answer, so it must not claim a backend
/// is missing.
public enum BackendCatalogState: Equatable, Sendable {
    case loading
    case available
    case degraded
}

// MARK: - BackendCatalogEntry

/// One backend as `polybridge-ctl backends` reports it. `installed` is `nil` — "unknown" — whenever
/// the catalog is degraded; it is only ever `true`/`false` right after a successful fetch.
public struct BackendCatalogEntry: Equatable, Identifiable, Sendable {
    public var id: String { backend }
    public let backend: String
    public let installed: Bool?

    public init(backend: String, installed: Bool?) {
        self.backend = backend
        self.installed = installed
    }
}

// MARK: - BackendCatalog

/// One coherent snapshot: the backends polybridge reports, in registry order, plus whether the last
/// fetch succeeded. `entries` is never merged with task history here — that union (Design point 3)
/// is the Sidebar/New Session VMs' job, since only they know the task list.
public struct BackendCatalog: Equatable, Sendable {
    public let entries: [BackendCatalogEntry]
    public let state: BackendCatalogState

    public init(entries: [BackendCatalogEntry], state: BackendCatalogState) {
        self.entries = entries
        self.state = state
    }

    public static let empty = BackendCatalog(entries: [], state: .loading)
}

// MARK: - BackendsRepository

/// `polybridge-ctl backends`, refreshed at startup (after tool discovery), on a tool-directory
/// change, after a successful polybridge install/update, on a bounded app-activation cadence, and on
/// demand — coalesced exactly like `TaskListRepository.refresh()`, so no two fetches ever run
/// concurrently and a stale answer can never land after a fresher one.
@Mockable
public protocol BackendsRepository: Sendable {

    var catalog: BackendCatalog { get }
    func catalogPublisher() -> AnyPublisher<BackendCatalog, Never>

    /// Discovery → first fetch, exactly once (mirrors `TaskListRepository.start()`). A second call
    /// is a no-op.
    func start()

    /// Refresh coalescing: a refresh already in flight arms one more pass rather than running
    /// concurrently.
    func refresh() async

    /// Called after `SettingsRepository.setToolDirectory` — triggers a refresh only.
    func settingsChanged()

    /// Called on `NSApplication.didBecomeActiveNotification` — internally bounded to at most once
    /// per 60 s, so switching back to the app repeatedly doesn't spawn a `ctl` call per switch.
    func appDidBecomeActive()
}

// MARK: - NullBackendsRepository

public struct NullBackendsRepository: BackendsRepository {
    public init() {}
    public var catalog: BackendCatalog { .empty }
    public func catalogPublisher() -> AnyPublisher<BackendCatalog, Never> { Just(.empty).eraseToAnyPublisher() }
    public func start() {}
    public func refresh() async {}
    public func settingsChanged() {}
    public func appDidBecomeActive() {}
}

// MARK: - GlobalValues

public extension GlobalValues {

    /// Global backends-catalog repository.
    @GlobalEntry var backendsRepository: any BackendsRepository = NullBackendsRepository()
}
