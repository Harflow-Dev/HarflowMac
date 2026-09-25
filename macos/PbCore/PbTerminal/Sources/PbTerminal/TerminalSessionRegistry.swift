import Combine
import Foundation
import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - StartInteractiveError

/// `Result`'s failure type must conform to `Error`, so the exact copy text
/// `"Could not start <backend>: <error>"` (F4-21) is carried in this wrapper rather than a bare
/// `String`.
public struct StartInteractiveError: Error, Equatable, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
}

// MARK: - TerminalSessionRegistry

/// Every embedded terminal the app has started — take-overs and interactive sessions — exactly
/// `AppModel.sessions`/`session(forTask:)`/`interactiveSessions`/`removeSession`
/// (`AppModel.swift:32,407-437`). `@MainActor` because it owns `NSView`-backed sessions — an
/// explicit exception to the repository-layer's `nonisolated` rule (decision 5).
///
/// The registry never reads the current selection: it only publishes when a session ends, so
/// `MainWindowFeature.MainWindowCoordinator` (which owns the selection since Phase 4d part 2) can
/// apply "remove an ended interactive session unless it is selected" itself (F4-21/F4-22).
@MainActor
@Mockable
public protocol TerminalSessionRegistry: AnyObject {

    var sessions: [TerminalSession] { get }
    func sessionsPublisher() -> AnyPublisher<[TerminalSession], Never>

    /// Interactive sessions that have not ended (`AppModel.swift:437-439`).
    var interactiveSessions: [TerminalSession] { get }

    /// The most recent take-over session for `taskID` (`AppModel.swift:407-409`) — "the latest
    /// takeover session wins" (F4-20).
    func session(forTask taskID: String) -> TerminalSession?

    /// Appends `session` and starts publishing its `onEnded` event. Callers append **before**
    /// calling `session.start()` (F4-18/F4-21), so a start failure is still visible in `sessions`.
    func add(_ session: TerminalSession)

    /// Terminates, then removes immediately without waiting for the outcome (F4-22).
    func remove(_ session: TerminalSession)

    /// Fires once per session, the first time it ends — whatever its kind. A coordinator decides
    /// what to do with it; the registry itself never removes on this event.
    func endedSessionsPublisher() -> AnyPublisher<TerminalSession, Never>

    /// Builds and starts a new interactive session: `InteractiveSession.command(backend:repo:...)`,
    /// title `"<backend> · <repo, formatted>"`, appended before `start()` (`AppModel.swift:412-429`).
    /// - Returns: the started session, or the exact error text `"Could not start <backend>: <error>"`.
    @discardableResult
    func startInteractive(backend: String, repo: String, environment: [String: String]) -> Result<TerminalSession, StartInteractiveError>
}

// MARK: - NullTerminalSessionRegistry

/// A `nonisolated` witness for the `@MainActor` protocol above, so the `@GlobalEntry` default below
/// never calls a `@MainActor` initializer (the root AGENTS.md's rule 6) — see this package's
/// `README.md`/`AGENTS.md` for why a nonisolated dummy was chosen over a lazily-registered instance.
final class NullTerminalSessionRegistry: TerminalSessionRegistry {
    nonisolated init() {}
    nonisolated var sessions: [TerminalSession] { [] }
    nonisolated func sessionsPublisher() -> AnyPublisher<[TerminalSession], Never> { Just([]).eraseToAnyPublisher() }
    nonisolated var interactiveSessions: [TerminalSession] { [] }
    nonisolated func session(forTask _: String) -> TerminalSession? { nil }
    nonisolated func add(_: TerminalSession) {}
    nonisolated func remove(_: TerminalSession) {}
    nonisolated func endedSessionsPublisher() -> AnyPublisher<TerminalSession, Never> { Empty().eraseToAnyPublisher() }
    nonisolated func startInteractive(backend: String, repo _: String, environment _: [String: String]) -> Result<TerminalSession, StartInteractiveError> {
        .failure(StartInteractiveError(message: "Could not start \(backend): the session registry is not wired up"))
    }
}

// MARK: - GlobalValues

public extension GlobalValues {

    /// Global terminal-session registry.
    @GlobalEntry var terminalSessionRegistry: any TerminalSessionRegistry = NullTerminalSessionRegistry()
}
