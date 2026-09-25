import Foundation
import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - TakeoverDestination

/// Where a granted take-over is opened — `AppModel.Destination` (`AppModel.swift:324`).
public enum TakeoverDestination: Sendable {
    case embedded
    case terminalApp
}

// MARK: - TakeoverService

/// Owns the whole take-over flow app-scoped, so it outlives the view that started it (decision 5):
/// `ctl takeover` grant → build the wrapper argv (never joined into a shell string) → start the
/// embedded session or hand off to Terminal.app → `takeover-attach` → on refusal, terminate and
/// write the outcome — exactly `AppModel.takeover`/`openEmbedded`/`openInTerminalApp`
/// (`AppModel.swift:325-404`). `@MainActor` because it owns `TerminalSession`s (an explicit
/// exception to the repository layer's `nonisolated` rule, same as the session registry).
///
/// Busy and the outcome line are read and written only through `TaskActionRepository` (decision 4);
/// `takeover`/`takeoverAttach` themselves are raw passthroughs that touch neither (F3 — this is the
/// dependency-direction fix: `PbTerminal` depends on `PbRepository`, never the other way).
@MainActor
@Mockable
public protocol TakeoverService: AnyObject {

    /// Dispatches synchronously into a service-owned `Task` and returns immediately, so a caller
    /// (a Parallel column, say) can route to the task screen right after calling this — decision 5's
    /// call path is VM → UseCase → ViewRepository → `TakeoverService`.
    func beginTakeover(taskID: String, destination: TakeoverDestination)
}

// MARK: - NullTakeoverService

/// A nonisolated witness for the `@MainActor` protocol above — see `NullTerminalSessionRegistry`'s
/// header comment for why the `@GlobalEntry` default below must not call a `@MainActor` initializer.
final class NullTakeoverService: TakeoverService {
    nonisolated init() {}
    nonisolated func beginTakeover(taskID _: String, destination _: TakeoverDestination) {}
}

// MARK: - GlobalValues

public extension GlobalValues {

    /// Global takeover service.
    @GlobalEntry var takeoverService: any TakeoverService = NullTakeoverService()
}
