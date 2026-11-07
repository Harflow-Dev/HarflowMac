import AppKit
import Darwin
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

/// Opt-in CPU attribution runs for the streaming activity feed: synthetic input only, with no engine
/// or user-state access. Each variant is gated by its own environment variable holding a duration in
/// seconds (at least 60); a normal run skips every variant. Results are printed, not asserted.
@MainActor @Suite(.serialized) struct ActivityFeedStreamingCPUProfileTests {
    /// The issue-34 soak's tick, mounted through the same root wrapper the other variants use.
    @Test func givenRetainedFeed_whenStreamingIntoFixedRow_thenReportsCPU() async throws {
        try await profile(.fixedRow, gate: "HARFLOW_ACTIVITY_CPU_FIXED_SECONDS")
    }

    /// The fixed-row stream with the presentation-only Reduce Motion override, which pauses the
    /// streaming caret's animation timeline while leaving layout unchanged.
    @Test func givenRetainedFeed_whenStreamingWithoutCaretAnimation_thenReportsCPU() async throws {
        try await profile(.noCaretAnimation, gate: "HARFLOW_ACTIVITY_CPU_NO_CARET_SECONDS")
    }

    /// The fixed-row stream with every row array and snapshot prepared before streaming starts.
    @Test func givenRetainedFeed_whenStreamingPrebuiltSnapshots_thenReportsCPU() async throws {
        try await profile(.prebuiltSnapshots, gate: "HARFLOW_ACTIVITY_CPU_PREBUILT_SECONDS")
    }

    /// Each tick finalizes the streaming tail and appends a new streaming row.
    @Test func givenRetainedFeed_whenAppendingRows_thenReportsCPU() async throws {
        try await profile(.append, gate: "HARFLOW_ACTIVITY_CPU_APPEND_SECONDS")
    }

    /// The append stream with the caret animation paused, as in the no-caret variant.
    @Test func givenRetainedFeed_whenAppendingRowsWithoutCaretAnimation_thenReportsCPU() async throws {
        try await profile(.appendNoCaretAnimation, gate: "HARFLOW_ACTIVITY_CPU_APPEND_NO_CARET_SECONDS")
    }

    /// The fixed-row stream with the test root hosting view's sizing options cleared.
    @Test func givenRetainedFeed_whenStreamingWithoutRootSizingOptions_thenReportsCPU() async throws {
        try await profile(.rootSizingOff, gate: "HARFLOW_ACTIVITY_CPU_ROOT_SIZING_OFF_SECONDS")
    }

    // MARK: - Run

    private func profile(_ variant: CPUProfileVariant, gate: String) async throws {
        guard let configured = ProcessInfo.processInfo.environment[gate] else { return }
        guard let seconds = Double(configured), seconds.isFinite, seconds >= 60 else {
            print("HARFLOW_ACTIVITY_CPU variant=\(variant) skipped: \(gate)=\(configured) is not a finite number of seconds of at least 60")
            return
        }
        // given
        _ = NSApplication.shared
        var source = CPUProfileSource(variant: variant)
        let state = ParallelColumnUIState()
        state.retainedFirstID = source.rows.first?.id
        let reduceMotion: Bool? = [.noCaretAnimation, .appendNoCaretAnimation].contains(variant) ? true : nil
        let host = NSHostingView(rootView: CPUProfileRoot(feed: feed(source, state: state), reduceMotion: reduceMotion))
        if variant == .rootSizingOff { host.sizingOptions = [] }
        let window = activityMountedTestWindow(host, style: [.titled, .resizable])
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        let owner = try await settle(host: host, state: state)
        if variant == .prebuiltSnapshots { source.prebuild() }
        // when
        let report = try await stream(for: seconds, source: &source, host: host, owner: owner, state: state, reduceMotion: reduceMotion)
        // then
        let scroll = try #require(owner.scroll)
        let subtree = subtreeDescription(scroll)
        let rowCount = source.rows.count
        let quiet = try await quietCPU(source: &source, host: host, owner: owner, state: state, reduceMotion: reduceMotion)
        print("HARFLOW_ACTIVITY_CPU variant=\(variant) seconds=\(seconds) \(report) rows=\(rowCount) "
            + "hosts=\(owner.cells.count) \(subtree) \(quiet)")
    }

    /// CPU with no ticks while the tail is still streaming, then after the tail finishes.
    private func quietCPU(source: inout CPUProfileSource, host: NSHostingView<CPUProfileRoot>, owner: ActivityFeedNativeList.Coordinator,
                          state: ParallelColumnUIState, reduceMotion: Bool?) async throws -> String {
        let reference = Date()
        await observe(for: 1)
        let holdStart = try cpuMark(since: reference)
        await observe(for: 5)
        let holdEnd = try cpuMark(since: reference)
        let finished = source.finish()
        host.rootView = CPUProfileRoot(feed: feed(source, state: state), reduceMotion: reduceMotion)
        await waitUntil(timeout: 5) { owner.model?.activitySnapshot === finished }
        try #require(owner.model?.activitySnapshot === finished, "The finished snapshot must actually commit")
        await observe(for: 2)
        let idleStart = try cpuMark(since: reference)
        await observe(for: 5)
        let idleEnd = try cpuMark(since: reference)
        return "held_stream_cpu_cores=\(cpuRate([holdStart, holdEnd])) finished_idle_cpu_cores=\(cpuRate([idleStart, idleEnd]))"
    }

    private func settle(host: NSHostingView<CPUProfileRoot>, state: ParallelColumnUIState) async throws -> ActivityFeedNativeList.Coordinator {
        await waitUntil(timeout: 30) { state.viewportPositioned }
        try #require(state.viewportPositioned)
        let table = try #require(activityNativeDescendants(host).compactMap { $0 as? ActivityFeedNativeTableView }.first)
        let owner = try #require(table.owner)
        let scroll = try #require(table.enclosingScrollView)
        for index in stride(from: 0, to: 3000, by: 50) {
            table.scrollRowToVisible(index)
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        activityNativeRevealBottom(scroll)
        await waitUntil(timeout: 5) { state.followLive.isFollowing }
        try #require(state.followLive.isFollowing)
        await observe(for: 2)
        return owner
    }

    // swiftlint:disable:next function_parameter_count
    private func stream(for seconds: TimeInterval, source: inout CPUProfileSource, host: NSHostingView<CPUProfileRoot>,
                        owner: ActivityFeedNativeList.Coordinator, state: ParallelColumnUIState, reduceMotion: Bool?) async throws -> String {
        let counters = (owner.reconcileCount, owner.measurementCount, owner.rootRefreshCount)
        let started = Date()
        var marks = [try cpuMark(since: started)]
        var nextMark = started.addingTimeInterval(5)
        var tick = 0
        while Date().timeIntervalSince(started) < seconds {
            let due = Date().addingTimeInterval(0.2)
            let expected = source.advance(tick: tick)
            host.rootView = CPUProfileRoot(feed: feed(source, state: state), reduceMotion: reduceMotion)
            await waitUntil(timeout: 5) { owner.model?.activitySnapshot === expected }
            try #require(owner.model?.activitySnapshot === expected, "The streamed snapshot must actually commit")
            if Date() >= nextMark {
                marks.append(try cpuMark(since: started))
                nextMark = Date().addingTimeInterval(5)
            }
            tick += 1
            await waitUntil(timeout: 0.3) { Date() >= due }
        }
        marks.append(try cpuMark(since: started))
        let early = Array(marks.prefix(max(2, marks.count / 3)))
        let late = Array(marks.suffix(max(2, marks.count / 3)))
        let elapsed = marks.last?.elapsed ?? 1
        return "ticks=\(tick) ticks_per_second=\(Double(tick) / elapsed) early_cpu_cores=\(cpuRate(early)) "
            + "late_cpu_cores=\(cpuRate(late)) overall_cpu_cores=\(cpuRate(marks)) "
            + "reconciles=\(owner.reconcileCount - counters.0) measurements=\(owner.measurementCount - counters.1) "
            + "root_refreshes=\(owner.rootRefreshCount - counters.2)"
    }

    // MARK: - Helpers

    private func feed(_ source: CPUProfileSource, state: ParallelColumnUIState) -> ActivityFeedView {
        ActivityFeedView(rows: source.rows, activitySnapshot: source.snapshot, start: nil, history: EventHistoryState(),
                         isLoading: false, state: state, onLoadMore: nil)
    }

    /// The feed's native subtree size and the cost of one Auto Layout fitting-size pass over it.
    private func subtreeDescription(_ scroll: NSScrollView) -> String {
        let root = scroll.superview ?? scroll
        let views = activityNativeDescendants(root)
        let constraints = views.reduce(0) { $0 + $1.constraints.count }
        let rounds = 10
        let clock = ContinuousClock()
        let duration = clock.measure { for _ in 0 ..< rounds { _ = root.fittingSize } }
        let milliseconds = Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000
        return "subtree_views=\(views.count) subtree_constraints=\(constraints) fitting_size_ms=\(milliseconds / Double(rounds))"
    }

    private func observe(for seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        await waitUntil(timeout: seconds + 1) { Date() >= deadline }
    }

    private func cpuMark(since started: Date) throws -> (elapsed: Double, cpu: Double) {
        var usage = rusage()
        try #require(getrusage(RUSAGE_SELF, &usage) == 0)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        return (Date().timeIntervalSince(started), cpu)
    }

    private func cpuRate(_ marks: [(elapsed: Double, cpu: Double)]) -> Double {
        guard let first = marks.first, let last = marks.last, last.elapsed > first.elapsed else { return 0 }
        return (last.cpu - first.cpu) / (last.elapsed - first.elapsed)
    }
}

// MARK: - CPUProfileVariant

private enum CPUProfileVariant: Equatable {
    case fixedRow
    case noCaretAnimation
    case prebuiltSnapshots
    case append
    case appendNoCaretAnimation
    case rootSizingOff
}

// MARK: - CPUProfileRoot

/// The hosted root: the feed with an optional presentation-only Reduce Motion override.
private struct CPUProfileRoot: View {
    let feed: ActivityFeedView
    let reduceMotion: Bool?

    var body: some View {
        feed.environment(\.hfReduceMotionOverride, reduceMotion)
    }
}

// MARK: - CPUProfileSource

/// The synthetic stream: 3000 retained rows, then one change per tick.
private struct CPUProfileSource {
    private static let retained = 3000
    private static let cycleLength = 40

    let variant: CPUProfileVariant
    private(set) var rows: [ActivityRow]
    private(set) var snapshot: ActivityFeedSnapshot
    private var cycle: [([ActivityRow], ActivityFeedSnapshot)] = []

    init(variant: CPUProfileVariant) {
        self.variant = variant
        self.rows = (0 ..< Self.retained).map { index in
            ActivityRow.single(ActivityFixture.text(index, "Synthetic retained message \(index). Selectable reading content.", task: "soak"))
        }
        self.snapshot = ActivityFeedSnapshot.preparing(rows, previous: nil)
    }

    /// Prepares one full cycle of row arrays and snapshots, so streaming does no harness preparation.
    mutating func prebuild() {
        var previous = snapshot
        var working = rows
        cycle = (0 ..< Self.cycleLength).map { tick in
            working[working.count - 1] = Self.streamingRow(seq: Self.retained - 1, tick: tick)
            let next = ActivityFeedSnapshot.preparing(working, previous: previous)
            previous = next
            return (working, next)
        }
    }

    /// Ends the stream: the tail row stops streaming, keeping its identity.
    mutating func finish() -> ActivityFeedSnapshot {
        rows[rows.count - 1] = .single(ActivityFixture.text(rows.count - 1, "Synthetic stream finished.", task: "soak"))
        snapshot = ActivityFeedSnapshot.preparing(rows, previous: snapshot)
        return snapshot
    }

    /// Applies one tick and returns the snapshot the feed must commit.
    mutating func advance(tick: Int) -> ActivityFeedSnapshot {
        switch variant {
        case .fixedRow, .noCaretAnimation, .rootSizingOff:
            rows[rows.count - 1] = Self.streamingRow(seq: Self.retained - 1, tick: tick)
        case .prebuiltSnapshots:
            (rows, snapshot) = cycle[tick % cycle.count]
            return snapshot
        case .append, .appendNoCaretAnimation:
            let last = rows.count - 1
            rows[last] = .single(ActivityFixture.text(Self.retained - 1 + tick, "Synthetic finished message \(tick).", task: "soak"))
            rows.append(Self.streamingRow(seq: Self.retained + tick, tick: tick))
        }
        snapshot = ActivityFeedSnapshot.preparing(rows, previous: snapshot)
        return snapshot
    }

    private static func streamingRow(seq: Int, tick: Int) -> ActivityRow {
        .single(ActivityFixture.text(seq, "Synthetic streaming delta \(tick % 100). " + String(repeating: "bounded text ", count: tick % 8 + 1),
                                     task: "soak", streaming: true))
    }
}
