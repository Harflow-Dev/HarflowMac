import Foundation
import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - TakeoverService

/// Opens a task's session in Terminal.app — the only take-over destination the Monitor offers.
/// `ctl takeover` grant → `TerminalAppHandoff` writes the hand-off files → `/usr/bin/open -a
/// Terminal <script>` → the script itself runs `takeover-attach` before `exec`ing the CLI. Busy and
/// the outcome line are read and written only through `TaskActionRepository` (decision 4);
/// `takeover` itself is a raw passthrough that touches neither.
///
/// `nonisolated`/`Sendable` (decision 12): with no embedded `TerminalSession` to own any more, this
/// service keeps no mutable state of its own — busy/outcome live in `TaskActionRepository` — so the
/// `@MainActor` exception the embedded implementation needed no longer applies.
@Mockable
public protocol TakeoverService: Sendable {

    /// Dispatches synchronously into a service-owned `Task` and returns immediately, so a caller (a
    /// Parallel column, say) can route to the task screen right after calling this. The in-flight
    /// takeover is owned by this service, not by any caller — a view disappearing mid-handoff never
    /// cancels it.
    func beginTakeover(taskID: String)
}

// MARK: - NullTakeoverService

public struct NullTakeoverService: TakeoverService {
    public init() {}
    public func beginTakeover(taskID _: String) {}
}

// MARK: - GlobalValues

public extension GlobalValues {

    /// Global takeover service.
    @GlobalEntry var takeoverService: any TakeoverService = NullTakeoverService()
}
