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
