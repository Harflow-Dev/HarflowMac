import Darwin
import Foundation

// MARK: - MonitorMetrics

/// Opt-in, content-free JSONL measurements on stderr (`POLYBRIDGE_MONITOR_METRICS=1`).
/// Durations measure elapsed work, not pixels displayed by SwiftUI. RSS is a process high-water mark.
public enum MonitorMetrics {
    /// Fixed labels prevent identifiers, prompts, paths, and answers entering measurements.
    public enum Stage: String, Sendable {
        case transport, decode, workflowLoad, workflowReconciliation, workflowViewUpdate, sidebarViewUpdate
        case sidebarContentReady, workflowContentReady
        case sidebarPreparation, sidebarScheduling, sidebarBuild, sidebarApply, sidebarUpdateLatency
        case parallelPreparation, parallelScheduling, parallelBuild, parallelApply, parallelUpdateLatency
        case parallelViewport, parallelLeases
        case activityFold, activityPageRead
        case activityViewport, activityPaginationRequest, activityScrollRestore
        case detailPreparation, detailBuild, detailApply, detailUpdateLatency
    }

    private static let enabled = ProcessInfo.processInfo.environment["POLYBRIDGE_MONITOR_METRICS"] == "1"
    private static let lock = NSLock()

    /// Returns a monotonic start only when instrumentation is explicitly enabled.
    public static func begin() -> UInt64? {
        enabled ? DispatchTime.now().uptimeNanoseconds : nil
    }

    /// Emits one measurement. Byte counts describe stream sizes; a transport record represents one CLI invocation attempt.
    /// Optional sidebar counters report actual rendering writes and whether building occurred off the main thread.
    public static func end(_ start: UInt64?, stage: Stage, bytes: Int = 0, stderrBytes: Int = 0,
                           renderingWrites: Int? = nil, backgroundThread: Bool? = nil,
                           residentColumns: Int? = nil, leasedMembers: Int? = nil, builtColumns: Int? = nil) {
        guard let start else { return }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        var usage = rusage()
        let peak = getrusage(RUSAGE_SELF, &usage) == 0 ? usage.ru_maxrss : 0
        let data = encoded(stage: stage, elapsedNanoseconds: elapsed, bytes: bytes, peakRSSBytes: peak,
                           stderrBytes: stderrBytes, renderingWrites: renderingWrites, backgroundThread: backgroundThread,
                           residentColumns: residentColumns, leasedMembers: leasedMembers, builtColumns: builtColumns)
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(data)
    }

    static func encoded(stage: Stage, elapsedNanoseconds: UInt64, bytes: Int, peakRSSBytes: Int, stderrBytes: Int = 0,
                        renderingWrites: Int? = nil, backgroundThread: Bool? = nil,
                        residentColumns: Int? = nil, leasedMembers: Int? = nil, builtColumns: Int? = nil) -> Data {
        var record: [String: Any] = [
            "monitor_metric_version": 1, "stage": stage.rawValue,
            "duration_ms": Double(elapsedNanoseconds) / 1_000_000,
            "stdout_bytes": max(0, bytes), "stderr_bytes": max(0, stderrBytes), "peak_rss_bytes": max(0, peakRSSBytes),
            "monotonic_ns": DispatchTime.now().uptimeNanoseconds
        ]
        if let renderingWrites { record["rendering_writes"] = max(0, renderingWrites) }
        if let backgroundThread { record["background_thread"] = backgroundThread ? 1 : 0 }
        if let residentColumns { record["resident_columns"] = max(0, residentColumns) }
        if let leasedMembers { record["leased_members"] = max(0, leasedMembers) }
        if let builtColumns { record["built_columns"] = max(0, builtColumns) }
        var data = (try? JSONSerialization.data(withJSONObject: record, options: .sortedKeys)) ?? Data()
        data.append(0x0A)
        return data
    }
}
