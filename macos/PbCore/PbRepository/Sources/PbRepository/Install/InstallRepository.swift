import Combine
import Foundation
import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - InstallStage

/// One step of the guarded install pipeline: git → uv → polybridge → validate.
public enum InstallStage: Equatable, Sendable {
    case git
    case uv
    case polybridge
    case validate
}

// MARK: - InstallState

/// The install operation's state machine (settled plan, section 3). `running`/`failed`/`unresolved`
/// all carry the stage they're at, so a re-entry (`retry()`, `checkAgain()`) knows where to resume
/// without guessing from context.
public enum InstallState: Equatable, Sendable {
    case idle
    /// System `git` (via the Command Line Tools) isn't usable yet.
    case needsGit
    /// `uv` wasn't found; installing it needs its own confirmation (`installUvThenPolybridge()`).
    case needsUv
    /// `.validate` shows "Checking…"; it can take tens of seconds (`polybridge-setup --status`'s
    /// own 90 s cap).
    case running(InstallStage)
    /// Terminal: the named stage failed with a message a person can act on.
    case failed(stage: InstallStage, message: String)
    /// Not terminal: a timeout means an installer may still be running in the background. Only a
    /// read-only `checkAgain()` or an explicit `installAnyway()` can move on from here.
    case unresolved(stage: InstallStage)
    /// Terminal: validated, and the barrier refresh (`TaskListRepository.refreshAndWait()`)
    /// succeeded.
    case installed
}

// MARK: - InstallRepository

/// The shared "Install polybridge" operation and its state (settled plan, section 3): one guarded
/// pipeline (git → uv → polybridge → validate) driven by five entry points, each a no-op unless the
/// current state allows it.
@Mockable
public protocol InstallRepository: Sendable {

    var state: InstallState { get }
    func statePublisher() -> AnyPublisher<InstallState, Never>

    /// The message from the most recent validation attempt, whether it passed or failed — the
    /// detail text for `unresolved`/`failed(.validate)`, which carry no message of their own on the
    /// `unresolved` side. Cleared by `reset()`.
    var lastCheckMessage: String? { get }
    func lastCheckMessagePublisher() -> AnyPublisher<String?, Never>

    /// Set only when `installAnyway()` refuses because the running-installer probe matched — the
    /// reason to show alongside the still-`unresolved` state. `nil` at every other time.
    var installAnywayBlockedMessage: String? { get }
    func installAnywayBlockedMessagePublisher() -> AnyPublisher<String?, Never>

    /// Where the next install would land — the currently discovered `uv`'s `binDirectory`, or `nil`
    /// if `uv` hasn't been found yet. For confirmation-dialog copy only; the operation itself always
    /// captures its own destination fresh at its own start, never this snapshot.
    func destination() -> String?

    /// Allowed from `idle`, `failed`, `needsGit`, `needsUv` and `installed`. Runs the git check, then
    /// checks whether `uv` is already known; ends at `needsUv` or continues to the polybridge stage.
    func install() async

    /// Allowed from `needsUv` only. Runs the uv bootstrap (download, run, re-discover), then
    /// polybridge, then validate — all inside the same guarded operation.
    func installUvThenPolybridge() async

    /// Allowed from `failed`. Resumes at the failed stage; a `.validate` failure re-validates only.
    func retry() async

    /// Allowed from `unresolved` and `failed(.validate)`. Read-only: never mutates. From
    /// `failed(.validate)`, moves to `installed` or stays `failed(.validate)`. From `unresolved`,
    /// the only way out is `installed`; a failed check keeps `unresolved` (same stage) and updates
    /// `lastCheckMessage`.
    func checkAgain() async

    /// Allowed from `unresolved` only — the only path from `unresolved` to a new mutation. Blocked
    /// while the running-installer probe matches (see `installAnywayBlockedMessage`).
    /// - Returns: `true` if the reinstall was attempted; `false` if refused (wrong state, or the
    ///   probe blocked it).
    @discardableResult
    func installAnyway() async -> Bool

    /// Allowed from `failed` and `installed` only; never from `unresolved` or `running`. Clears the
    /// captured `uv`, `lastCheckMessage` and `installAnywayBlockedMessage`.
    func reset()
}

// MARK: - NullInstallRepository

public struct NullInstallRepository: InstallRepository {
    public init() {}
    public var state: InstallState { .idle }
    public func statePublisher() -> AnyPublisher<InstallState, Never> { Just(.idle).eraseToAnyPublisher() }
    public var lastCheckMessage: String? { nil }
    public func lastCheckMessagePublisher() -> AnyPublisher<String?, Never> { Just(nil).eraseToAnyPublisher() }
    public var installAnywayBlockedMessage: String? { nil }
    public func installAnywayBlockedMessagePublisher() -> AnyPublisher<String?, Never> { Just(nil).eraseToAnyPublisher() }
    public func destination() -> String? { nil }
    public func install() async {}
    public func installUvThenPolybridge() async {}
    public func retry() async {}
    public func checkAgain() async {}
    public func installAnyway() async -> Bool { false }
    public func reset() {}
}

// MARK: - GlobalValues

public extension GlobalValues {

    /// Global install repository.
    @GlobalEntry var installRepository: any InstallRepository = NullInstallRepository()
}
