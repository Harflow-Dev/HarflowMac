import Foundation

/// Ending a terminal's child and knowing that it ended. SwiftTerm's own `terminate()` sends one
/// SIGTERM and stops watching, so it can neither report the exit nor stop a child that ignores
/// SIGTERM — and a take-over child that outlives an attach refusal would be a second, unreserved
/// writer to the session. This escalates and reaps.
public enum ChildReaper {
    public enum Outcome: Equatable, Sendable {
        /// Reaped here; the raw wait status.
        case exited(status: Int32)
        /// Already reaped by someone else (SwiftTerm's own exit monitor): it is gone.
        case alreadyGone
        /// Still not reaped after SIGKILL and the final wait — should not happen; reported, never hidden.
        case survived
    }

    /// Only for a pid this process spawned (a child we may `waitpid`). Checks for an exit before
    /// every signal, so a pid that was already reaped — and could have been reused — is never
    /// signalled. Blocking; call off the main thread.
    public static func terminate(pid: pid_t, grace: TimeInterval = 3, killWait: TimeInterval = 3) -> Outcome {
        guard pid > 1 else { return .alreadyGone }
        if let done = reap(pid) { return done }
        // The pty child is its own session leader (forkpty), so its group is its pgid.
        signal(pid, [SIGHUP, SIGTERM])
        if let done = poll(pid, for: grace) { return done }
        if let done = reap(pid) { return done }
        signal(pid, [SIGKILL])
        return poll(pid, for: killWait) ?? .survived
    }

    private static func signal(_ pid: pid_t, _ signals: [Int32]) {
        for sig in signals {
            _ = kill(-pid, sig)
            _ = kill(pid, sig)
        }
    }

    /// nil while the child is still running.
    static func reap(_ pid: pid_t) -> Outcome? {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { return .exited(status: status) }
        if result == -1 && errno == ECHILD { return .alreadyGone }
        return nil
    }

    private static func poll(_ pid: pid_t, for seconds: TimeInterval) -> Outcome? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let done = reap(pid) { return done }
            usleep(50_000)
        } while Date() < deadline
        return reap(pid)
    }
}

/// Which file changes in the tasks folder can change what `polybridge-ctl list` says. A record
/// rewrite is the usual one, but a takeover or cancel writes only phase files
/// (`<id>.takeover.<n>.ready`, `<id>.cancel.<n>.sig`, …) and never touches the record — and
/// `taken_over` is derived from them.
public enum RefreshTrigger {
    public static func isRelevant(_ name: String) -> Bool {
        name.hasSuffix(".meta.json") || name.contains(".takeover.") || name.contains(".cancel.")
    }

    /// Reconcile this often even when nothing is running and no file event arrived.
    public static let reconcileInterval: TimeInterval = 60
}

/// The cascade part of `polybridge-ctl cancel`'s answer, in words. Cancel is best-effort, so
/// anything that did not stop is said, never implied away.
public enum CascadeSummary {
    public static func describe(_ result: [String: JSONValue]) -> String {
        let status = result["status"]?.stringValue ?? "unknown"
        var parts = ["Cancel sent · status \(status)"]
        guard let cascade = result["cascade"]?.objectValue else { return parts[0] }
        func count(_ key: String) -> Int { cascade[key]?.arrayValue?.count ?? 0 }
        let cancelled = count("cancelled_descendants")
        if cancelled > 0 { parts.append("\(cancelled) sub-task\(cancelled == 1 ? "" : "s") cancelled") }
        let problems: [(String, String)] = [
            ("sigkill_survivors", "survived SIGKILL"),
            ("owner_still_settling", "still settling under their own server"),
            ("not_signalled", "not signalled"),
            ("not_recorded", "signalled but not recorded"),
        ]
        for (key, words) in problems where count(key) > 0 {
            parts.append("\(count(key)) \(words)")
        }
        if result["unrecorded_phase_writes"]?.arrayValue?.isEmpty == false {
            parts.append("some signals could not be recorded")
        }
        return parts.joined(separator: " · ")
    }
}
