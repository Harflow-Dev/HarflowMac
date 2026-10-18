import Combine
import Foundation
import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - TaskActionRepository

/// The busy set and the durable per-task outcome line (decision 4), plus every ctl action —
/// `AppModel.perform`/`cancel`/`cancelAll`/`send`/`resume`/`startHeadless`
/// (`AppModel.swift:253-320`). Both `busy` and the outcome line are keyed by task id and outlive the
/// VM that started the action, because a write can legitimately land after that VM is gone (a
/// resume moves the selection away from the task that is being resumed; a Terminal.app hand-off
/// outcome arrives asynchronously, after `TakeoverService`'s own dispatch completes).
///
/// `cancel`/`send`/`resume` are `async throws` (decision 3): each writes its outcome line itself —
/// exactly like `AppModel.perform` — *before* it throws, so the text survives regardless of who is
/// still listening, and only then rethrows the `ToolError` behind a locator failure or the command's
/// own refusal, so a caller that wants to react to the failure (not just read the outcome line) can.
///
/// **Busy-rejected calls never throw.** A `taskID` already busy means "return without doing
/// anything" (F4-14) — no ctl call, no outcome write, no error. The contract for telling that case
/// apart from a real attempt is per method, documented at each one: `cancel`/`send` return `false`;
/// `resume` returns `nil`. Both are unambiguous once genuine failures throw instead of returning a
/// sentinel: `false`/`nil` now means exactly one thing.
///
/// `run` and `takeover` are the two genuinely raw operations: `run`'s error goes to the caller (the
/// New Session sheet), never the outcome line (F4-17), and `takeover` touches neither busy nor
/// outcome at all — that is `TakeoverService`'s job. `takeover-attach` itself is invoked by the
/// Terminal.app hand-off script directly (`polybridge-ctl takeover-attach`), never by this app.
@Mockable
public protocol TaskActionRepository: Sendable {

    var busy: Set<String> { get }
    func busyPublisher() -> AnyPublisher<Set<String>, Never>

    func outcome(_ taskID: String) -> String?
    func outcomesPublisher() -> AnyPublisher<[String: String], Never>

    /// Atomic check-and-insert: `false` if `taskID` was already busy.
    @discardableResult
    func tryBeginBusy(_ taskID: String) -> Bool
    func endBusy(_ taskID: String)
    func setOutcome(_ taskID: String, _ text: String?)

    /// Writes the cascade summary (or the error message) as the outcome, then rethrows on failure.
    /// - Returns: `true` if the cancel was attempted; `false` if `taskID` was already busy (in which
    ///   case nothing was written and nothing is thrown).
    /// - Throws: the `ToolError` behind a locator failure or the command's own refusal.
    @discardableResult
    func cancel(_ taskID: String) async throws -> Bool
    /// One independent `cancel` per id, each with its own busy guard and outcome (F4-15). A member's
    /// failure — its own `cancel` throwing — never stops the others; every id is attempted.
    func cancelAll(_ ids: [String]) async
    /// Writes "Queued…" (or the error message) as the outcome, then rethrows on failure.
    /// - Returns: `true` if the send was attempted; `false` if `taskID` was already busy.
    /// - Throws: the `ToolError` behind a locator failure or the command's own refusal.
    @discardableResult
    func send(_ taskID: String, text: String) async throws -> Bool
    /// Writes "Follow-up sent — the reply will appear below." (or the error message) as the outcome,
    /// then rethrows on failure. `ctl resume` still creates a new task id under the hood (the agent
    /// session literally continues as a new process), but the Monitor shows it as the SAME
    /// conversation continuing (Monitor piece 7) — so the caller no longer routes anywhere on
    /// success; `onResumed` exists only so a caller can react to the new id if it ever needs to
    /// (e.g. for its own bookkeeping), never to navigate.
    ///
    /// `onResumed` fires exactly once, synchronously, right after `ctl resume` returns a new id —
    /// **before** `endBusy`, the outcome write, and both refreshes.
    /// It never fires on a busy-rejection or a failure.
    /// - Returns: the new task id on success; `nil` if `taskID` was already busy (in which case
    ///   nothing was written and nothing is thrown). Failure is signalled only by throwing, never by
    ///   `nil` — so `nil` unambiguously means "rejected because busy."
    /// - Throws: the `ToolError` behind a locator failure or the command's own refusal.
    @discardableResult
    func resume(_ taskID: String, text: String, onResumed: @escaping @Sendable (String) async -> Void) async throws -> String?

    /// Refreshes the listing before returning, so a caller can route to the new task once this
    /// returns (F4-17). Throws to the caller on failure; never writes an outcome line.
    func run(_ request: RunRequest) async throws -> String

    /// Raw passthrough to `ctl takeover` — touches neither busy nor outcome. Takes the `CtlClient`
    /// the caller already located, so `TakeoverService` never has to re-locate one.
    func takeover(_ taskID: String, using client: CtlClient) async throws -> TakeoverGrant
}

// MARK: - NullTaskActionRepository

public struct NullTaskActionRepository: TaskActionRepository {
    public init() {}
    public var busy: Set<String> { [] }
    public func busyPublisher() -> AnyPublisher<Set<String>, Never> { Just([]).eraseToAnyPublisher() }
    public func outcome(_: String) -> String? { nil }
    public func outcomesPublisher() -> AnyPublisher<[String: String], Never> { Just([:]).eraseToAnyPublisher() }
    public func tryBeginBusy(_: String) -> Bool { false }
    public func endBusy(_: String) {}
    public func setOutcome(_: String, _: String?) {}
    public func cancel(_: String) async throws -> Bool { throw ToolError.notFound(tool: "polybridge-ctl", searched: []) }
    public func cancelAll(_: [String]) async {}
    public func send(_: String, text _: String) async throws -> Bool { throw ToolError.notFound(tool: "polybridge-ctl", searched: []) }
    public func resume(_: String, text _: String, onResumed _: @escaping @Sendable (String) async -> Void) async throws -> String? {
        throw ToolError.notFound(tool: "polybridge-ctl", searched: [])
    }

    public func run(_: RunRequest) async throws -> String { throw ToolError.notFound(tool: "polybridge-ctl", searched: []) }
    public func takeover(_: String, using _: CtlClient) async throws -> TakeoverGrant { throw ToolError.notFound(tool: "polybridge-ctl", searched: []) }
}

// MARK: - GlobalValues

public extension GlobalValues {

    /// Global task-action repository.
    @GlobalEntry var taskActionRepository: any TaskActionRepository = NullTaskActionRepository()
}
