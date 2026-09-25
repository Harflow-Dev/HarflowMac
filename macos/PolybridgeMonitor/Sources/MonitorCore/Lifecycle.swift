import Darwin
import Foundation

/// A process as the kernel's process table reports it: pid plus start time, which together name
/// one process even after the pid is reused — the same rule polybridge's own `identity.py` uses.
public struct ProcessIdentity: Equatable, Hashable, Sendable {
    public let pid: pid_t
    public let startSeconds: Int
    public let startMicros: Int32
}

public enum ProcessTable {
    public struct Entry: Equatable, Sendable {
        public let identity: ProcessIdentity
        public let pgid: pid_t
        public let zombie: Bool
    }

    static func entry(_ info: kinfo_proc) -> Entry {
        let start = info.kp_proc.p_un.__p_starttime
        return Entry(
            identity: ProcessIdentity(pid: info.kp_proc.p_pid, startSeconds: start.tv_sec, startMicros: start.tv_usec),
            pgid: info.kp_eproc.e_pgid,
            zombie: info.kp_proc.p_stat == SZOMB
        )
    }

    public static func lookup(_ pid: pid_t) -> Entry? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        return entry(info)
    }

    /// Every process whose process group is `pgid`.
    public static func group(_ pgid: pid_t) -> [Entry] {
        guard pgid > 0 else { return [] }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 8)
        size = buffer.count * stride
        guard sysctl(&mib, 4, &buffer, &size, nil, 0) == 0 else { return [] }
        return buffer.prefix(size / stride).map(entry).filter { $0.pgid == pgid }
    }

    /// Alive and still the same process (a zombie has exited; a different start time is a reuse).
    public static func isLive(_ identity: ProcessIdentity) -> Bool {
        guard let entry = lookup(identity.pid) else { return false }
        return entry.identity == identity && !entry.zombie
    }
}

/// Ending a terminal's child — and its process group — and knowing that it ended.
///
/// SwiftTerm's own `terminate()` sends one unchecked SIGTERM to a pid it may already have reaped,
/// and stops watching. A take-over child that outlives an attach refusal would be a second,
/// unreserved writer to the session, so this never calls it. Instead: every signal goes to a
/// process whose (pid, start time) was just re-read and still matches, so a reused pid is never
/// signalled; the whole group is covered (a launcher can exit on SIGTERM while the agent it started
/// ignores it); and success means none of them is alive any more. Reaping is left to SwiftTerm's
/// own exit monitor; a zombie counts as gone. Blocking — call off the main thread.
public enum ChildReaper {
    public enum Outcome: Equatable, Sendable {
        /// The leader and every group member seen are gone.
        case stopped
        /// The leader was already gone (or never matched) before anything was signalled.
        case alreadyGone
        /// Still alive after SIGKILL and the final wait — reported, never hidden.
        case survived([pid_t])
    }

    public static func terminate(_ leader: ProcessIdentity, grace: TimeInterval = 3, killWait: TimeInterval = 3) -> Outcome {
        var targets = Set<ProcessIdentity>()
        func rescan() {
            if ProcessTable.isLive(leader) { targets.insert(leader) }
            // The pty child is its own session and group leader, so the group id is its pid. The
            // group is re-read on every pass, so a member forked meanwhile is covered too.
            for member in ProcessTable.group(leader.pid) where !member.zombie { targets.insert(member.identity) }
        }
        func live() -> [ProcessIdentity] { targets.filter(ProcessTable.isLive) }
        func signal(_ sig: Int32) {
            for target in live() { _ = kill(target.pid, sig) }
        }

        guard ProcessTable.isLive(leader) else { return .alreadyGone }
        rescan()
        signal(SIGHUP)
        signal(SIGTERM)
        if wait(for: grace, rescan: rescan, live: live) { return .stopped }
        rescan()
        signal(SIGKILL)
        if wait(for: killWait, rescan: rescan, live: live) { return .stopped }
        return .survived(live().map(\.pid).sorted())
    }

    private static func wait(for seconds: TimeInterval, rescan: () -> Void, live: () -> [ProcessIdentity]) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            rescan()
            if live().isEmpty { return true }
            usleep(50_000)
        } while Date() < deadline
        rescan()
        return live().isEmpty
    }
}

/// A raw `waitpid` status — what SwiftTerm hands `processTerminated` — decoded.
public enum WaitStatus: Equatable, Sendable {
    case exited(Int32)
    case signalled(Int32)

    public init(raw: Int32) {
        let low = raw & 0x7f
        self = low == 0 ? .exited((raw >> 8) & 0xff) : .signalled(low)
    }

    public var label: String {
        switch self {
        case .exited(let code): return "exit \(code)"
        case .signalled(let sig): return "signal \(sig)"
        }
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
