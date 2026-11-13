import Combine
import Foundation
import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - BackendCatalogState

/// Whether the last `harflow-ctl backends` fetch actually succeeded. `.degraded` covers every
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

/// One backend as `harflow-ctl backends` reports it. `installed` is `nil` — "unknown" — whenever
/// the catalog is degraded; it is only ever `true`/`false` right after a successful fetch.
public struct BackendCatalogEntry: Equatable, Identifiable, Sendable {
    public var id: String { backend }
    public let backend: String
    public let installed: Bool?
    public let supportsCallerApprovals: Bool
    /// The run-option facts the engine reported; `.unknown` whenever the catalog is degraded.
    public let controls: BackendControlFacts

    public init(
        backend: String,
        installed: Bool?,
        supportsCallerApprovals: Bool = false,
        controls: BackendControlFacts = .unknown
    ) {
        self.backend = backend
        self.installed = installed
        self.supportsCallerApprovals = supportsCallerApprovals
        self.controls = controls
    }
}

// MARK: - ControlState

/// Whether one run-option control applies to a harness: the engine said yes, said no, or the app
/// cannot tell (catalog loading or degraded, or the engine omitted the fact).
public enum ControlState: Equatable, Sendable {
    case supported
    case unsupported
    case unknown
}

// MARK: - EffortState

/// The reasoning-effort control of a harness. `.levels` is never empty and keeps the engine's
/// order; levels the engine did not report are never invented.
public enum EffortState: Equatable, Sendable {
    case levels([String])
    case unsupported
    case unknown
}

// MARK: - BackendControls

/// What a feature may offer for one harness: model, effort and turn-limit controls, each three-state.
/// Derived only from engine-reported facts of an `.available` catalog, never from a backend name.
public struct BackendControls: Equatable, Sendable {
    public let model: ControlState
    public let effort: EffortState
    public let turnCap: ControlState

    public init(model: ControlState, effort: EffortState, turnCap: ControlState) {
        self.model = model
        self.effort = effort
        self.turnCap = turnCap
    }

    /// Nothing is known: the catalog is loading or degraded, or the backend is not listed.
    public static let unavailable = BackendControls(model: .unknown, effort: .unknown, turnCap: .unknown)

    /// Maps engine facts to control states. A missing fact is `.unknown`; the model control also
    /// needs a usable qualification gate (`.notReady` is `.unsupported`, `.unknown` is `.unknown`).
    public init(facts: BackendControlFacts) {
        switch facts.supportsModelSelection {
        case nil: self.model = .unknown
        case false?: self.model = .unsupported
        case true?:
            switch facts.modelSelection {
            case .notDeclared, .ready: self.model = .supported
            case .notReady: self.model = .unsupported
            case .unknown: self.model = .unknown
            }
        }
        switch facts.effort {
        case nil: self.effort = .unknown
        case let block?: self.effort = block.acceptsParameter && !block.levels.isEmpty ? .levels(block.levels) : .unsupported
        }
        switch facts.supportsTurnCap {
        case nil: self.turnCap = .unknown
        case true?: self.turnCap = .supported
        case false?: self.turnCap = .unsupported
        }
    }
}

// MARK: - BackendCatalog

/// One coherent snapshot: the backends harflow reports, in registry order, plus whether the last
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

    /// The run-option controls for `backend`: `.unavailable` unless the catalog is `.available` and
    /// lists that backend, so loading, degraded and unlisted all read as unknown.
    public func controls(for backend: String) -> BackendControls {
        guard state == .available, let entry = entries.first(where: { $0.backend == backend }) else { return .unavailable }
        return BackendControls(facts: entry.controls)
    }
}

// MARK: - BackendsRepository

/// `harflow-ctl backends`, refreshed at startup (after tool discovery), on a tool-directory
/// change, after a successful harflow install/update, on a bounded app-activation cadence, and on
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
