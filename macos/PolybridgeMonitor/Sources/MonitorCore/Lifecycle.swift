import Darwin
import Foundation

/// A process as the kernel's process table reports it: pid plus start time, which together name
/// one process even after the pid is reused — the same rule polybridge's own `identity.py` uses.
public struct ProcessIdentity: Equatable, Hashable, Sendable {
    public let pid: pid_t
    public let startSeconds: Int
    public let startMicros: Int32
}

/// Reads of the kernel process table. A failed read is `unreadable`, never "absent": missing
/// evidence is not evidence of death (polybridge's own identity checks keep an `undecidable`
/// verdict for the same reason).
public protocol ProcessTableReading: Sendable {
    func lookup(_ pid: pid_t) -> ProcessTable.Lookup
    /// Every process whose group is `pgid`, or nil when the table could not be read.
    func group(_ pgid: pid_t) -> [ProcessTable.Entry]?
}

public enum ProcessTable {
    public struct Entry: Equatable, Sendable {
        public let identity: ProcessIdentity
        public let pgid: pid_t
        public let zombie: Bool

        public init(identity: ProcessIdentity, pgid: pid_t, zombie: Bool) {
            self.identity = identity
            self.pgid = pgid
            self.zombie = zombie
        }
    }

    public enum Lookup: Equatable, Sendable {
        case entry(Entry)
        case absent
        case unreadable
    }

    public enum Liveness: Equatable, Sendable { case live, gone, undecidable }

    public static let system: ProcessTableReading = SystemProcessTable()

    public static func lookup(_ pid: pid_t) -> Entry? {
        if case .entry(let entry) = system.lookup(pid) { return entry }
        return nil
    }

    public static func group(_ pgid: pid_t) -> [Entry] { system.group(pgid) ?? [] }

    /// Alive and still the same process (a zombie has exited; a different start time is a reuse).
    public static func isLive(_ identity: ProcessIdentity) -> Bool { liveness(identity, in: system) == .live }

    public static func liveness(_ identity: ProcessIdentity, in table: ProcessTableReading) -> Liveness {
        switch table.lookup(identity.pid) {
        case .entry(let entry): return entry.identity == identity && !entry.zombie ? .live : .gone
        case .absent: return .gone
        case .unreadable: return .undecidable
        }
    }
}

struct SystemProcessTable: ProcessTableReading {
    static func entry(_ info: kinfo_proc) -> ProcessTable.Entry {
        let start = info.kp_proc.p_un.__p_starttime
        return ProcessTable.Entry(
            identity: ProcessIdentity(pid: info.kp_proc.p_pid, startSeconds: start.tv_sec, startMicros: start.tv_usec),
            pgid: info.kp_eproc.e_pgid,
            zombie: info.kp_proc.p_stat == SZOMB
        )
    }

    func lookup(_ pid: pid_t) -> ProcessTable.Lookup {
        guard pid > 0 else { return .absent }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return .unreadable }
        if size == 0 { return .absent }
        guard size >= MemoryLayout<kinfo_proc>.stride else { return .unreadable }
        return .entry(Self.entry(info))
    }

    func group(_ pgid: pid_t) -> [ProcessTable.Entry]? {
        guard pgid > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        // The group can grow between sizing and reading (ENOMEM): size again, a few times.
        for _ in 0..<5 {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid]
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return nil }
            if size == 0 { return [] }
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
            size = buffer.count * stride
            if sysctl(&mib, 4, &buffer, &size, nil, 0) == 0 {
                return buffer.prefix(size / stride).map(Self.entry).filter { $0.pgid == pgid }
            }
            guard errno == ENOMEM else { return nil }
        }
        return nil
    }
}

/// Ending a terminal's child — and its process group — and knowing that it ended.
///
/// SwiftTerm's own `terminate()` sends one unchecked SIGTERM to a pid it may already have reaped,
/// and stops watching; a take-over child that outlives an attach refusal would be a second,
/// unreserved writer to the session. So this never calls it, and:
/// - every signal goes to a process whose (pid, start time) was just re-read and still matches;
/// - the leader's whole group is covered, but a group member is admitted only while the group is
///   provably still the original one — the leader still holds its pid (alive or a zombie), or a
///   member already known to be ours is still in it. Once that continuity breaks, or another
///   process leads the group id, nothing new is admitted: a reused group id is someone else's;
/// - a table read that fails is never taken as death: the result is `.unconfirmed`, not `.stopped`.
/// Reaping is left to SwiftTerm's own exit monitor. Blocking — call off the main thread.
public enum ChildReaper {
    public enum Outcome: Equatable, Sendable {
        /// Every process of the group that was provably ours is gone.
        case stopped
        /// The leader was already gone and nothing was left in its group.
        case alreadyGone
        /// Still alive after SIGKILL and the final wait.
        case survived([pid_t])
        /// Could not be established either way — never reported as stopped.
        case unconfirmed(pids: [pid_t], reason: String)
    }

    public static func terminate(
        _ leader: ProcessIdentity,
        grace: TimeInterval = 3,
        killWait: TimeInterval = 3,
        table: ProcessTableReading = ProcessTable.system,
        send: (pid_t, Int32) -> Void = { _ = kill($0, $1) }
    ) -> Outcome {
        var known = Set<ProcessIdentity>()
        var groupOpen = true
        var lastScanFailed = false
        /// A group scan failed at some point, so members may exist that were never seen. Cleared
        /// only by a complete scan that re-establishes continuity (they are then admitted) or that
        /// proves no process in the original group id is alive.
        var coverageGap = false
        /// Set when continuity was lost during a coverage gap: the processes then in the group id
        /// can be neither proven ours nor proven not ours. Never signalled; the result cannot be
        /// `.stopped` until a complete scan shows the group id empty (or taken by a new leader).
        var unproven: [pid_t] = []
        var awaitingProof = false

        func liveness(_ identity: ProcessIdentity) -> ProcessTable.Liveness { ProcessTable.liveness(identity, in: table) }

        /// nil: unreadable. true: the leader's pid is still held by the leader (alive or zombie).
        func leaderHoldsPid() -> Bool? {
            switch table.lookup(leader.pid) {
            case .entry(let entry): return entry.identity == leader
            case .absent: return false
            case .unreadable: return nil
            }
        }

        func rescan() {
            if awaitingProof {
                guard let members = table.group(leader.pid) else { lastScanFailed = true; return }
                lastScanFailed = false
                let live = members.filter { !$0.zombie }
                // A pid cannot be reused while it is a live group id, so a different process
                // leading the id means the original group emptied first.
                if live.isEmpty || live.contains(where: { $0.identity.pid == leader.pid && $0.identity != leader }) {
                    awaitingProof = false
                    unproven = []
                } else {
                    unproven = live.map(\.identity.pid).sorted()
                }
                return
            }
            guard groupOpen else { lastScanFailed = false; return }
            guard let held = leaderHoldsPid(), let members = table.group(leader.pid) else {
                lastScanFailed = true
                coverageGap = true
                return
            }
            lastScanFailed = false
            if let head = members.first(where: { $0.identity.pid == leader.pid }), head.identity != leader {
                groupOpen = false // another process now leads this group id: the original is gone
                coverageGap = false
                return
            }
            let memberIDs = Set(members.map(\.identity))
            let continuous = held || known.contains { memberIDs.contains($0) && liveness($0) == .live }
            guard continuous else {
                groupOpen = false // the original group emptied, or we lost track of it
                let live = members.filter { !$0.zombie }
                if coverageGap && !live.isEmpty {
                    // Seen for the first time after a gap, with nothing tying them to us.
                    awaitingProof = true
                    unproven = live.map(\.identity.pid).sorted()
                }
                coverageGap = false
                return
            }
            for member in members where !member.zombie { known.insert(member.identity) }
            coverageGap = false
        }

        func signal(_ sig: Int32) {
            for target in known where liveness(target) == .live { send(target.pid, sig) }
        }

        func settled() -> Bool {
            !lastScanFailed && !coverageGap && !awaitingProof && known.allSatisfy { liveness($0) == .gone }
        }

        func wait(_ seconds: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            repeat {
                rescan()
                if settled() { return true }
                usleep(50_000)
            } while Date() < deadline
            rescan()
            return settled()
        }

        switch leaderHoldsPid() {
        case .none:
            return .unconfirmed(pids: [leader.pid], reason: "the process table could not be read")
        case .some(false):
            // The leader is gone and reaped, so nothing ties the group id to it any more.
            guard let members = table.group(leader.pid) else {
                return .unconfirmed(pids: [], reason: "the process table could not be read")
            }
            let left = members.filter { !$0.zombie }.map(\.identity.pid).sorted()
            return left.isEmpty ? .alreadyGone : .unconfirmed(pids: left, reason: "the terminal's process had already exited; what is left in its process group cannot be shown to be its own, so it was not signalled")
        case .some(true):
            known.insert(leader)
        }

        rescan()
        if settled() { return liveness(leader) == .gone && known.count == 1 ? .alreadyGone : .stopped }
        signal(SIGHUP)
        signal(SIGTERM)
        if wait(grace) { return .stopped }
        rescan()
        signal(SIGKILL)
        if wait(killWait) { return .stopped }

        let alive = known.filter { liveness($0) == .live }.map(\.pid).sorted()
        if !alive.isEmpty { return .survived(alive) }
        if awaitingProof {
            return .unconfirmed(pids: unproven, reason: "processes appeared in the terminal's process group after a scan that could not be read; they cannot be shown to be its own, so they were not signalled")
        }
        let unknown = known.filter { liveness($0) == .undecidable }.map(\.pid).sorted()
        return .unconfirmed(pids: unknown, reason: "the process table could not be read")
    }
}

/// Taking ownership of a child the terminal just forked: its identity (pid + start time) is what
/// every later signal and the takeover attach depend on. If it cannot be read, the child is not
/// left running unattached — a take-over CLI that nobody reserved would be a second writer to the
/// session — it is killed, with its process group, by the pid the fork returned.
public enum ChildAdoption {
    public enum Failure: Error, Equatable, Sendable {
        /// Identity unreadable; the child and its group were sent SIGKILL.
        case killed(pid_t)
    }

    /// `lookup` is retried a few times (a transient table read). The pid is this process's own
    /// fork from moments earlier and not yet reaped by us, so signalling it is signalling our
    /// child; the forkpty child is its own session and group leader, hence `-pid` too.
    public static func adopt(
        _ pid: pid_t,
        attempts: Int = 3,
        lookup: (pid_t) -> ProcessTable.Lookup = { ProcessTable.system.lookup($0) },
        send: (pid_t, Int32) -> Void = { _ = kill($0, $1) }
    ) -> Result<ProcessIdentity, Failure> {
        for attempt in 0..<max(1, attempts) {
            if case .entry(let entry) = lookup(pid), entry.identity.pid == pid, !entry.zombie {
                return .success(entry.identity)
            }
            if attempt + 1 < attempts { usleep(20_000) }
        }
        send(-pid, SIGKILL)
        send(pid, SIGKILL)
        return .failure(.killed(pid))
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
        if cascade["cascade_incomplete"]?.boolValue == true {
            let missed = count("unconverged")
            parts.append("cascade incomplete" + (missed > 0 ? ": \(missed) descendant\(missed == 1 ? "" : "s") never reached" : ""))
        }
        if result["unrecorded_phase_writes"]?.arrayValue?.isEmpty == false {
            parts.append("some signals could not be recorded")
        }
        return parts.joined(separator: " · ")
    }
}
