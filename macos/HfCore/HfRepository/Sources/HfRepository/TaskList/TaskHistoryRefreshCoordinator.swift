import Foundation
import MonitorCore

// MARK: - TaskHistoryRefreshCoordinator

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
actor TaskHistoryRefreshCoordinator {
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
