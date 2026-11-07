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

    /// A pending tool call (the running spinner) ends the feed; ticks rewrite the settled row above it.
    @Test func givenRetainedFeed_whenToolCallIsPending_thenReportsCPU() async throws {
        try await profile(.liveTool, gate: "HARFLOW_ACTIVITY_CPU_LIVE_TOOL_SECONDS")
    }

    /// The standard style's live step line (the pulsing dot) sits under the feed; ticks rewrite the last settled row.
    @Test func givenRetainedFeed_whenLiveStepPulses_thenReportsCPU() async throws {
        try await profile(.liveStepPulse, gate: "HARFLOW_ACTIVITY_CPU_LIVE_STEP_SECONDS")
    }

    /// The transcript style's working row (the turning working glyph) sits under the feed; ticks rewrite the last settled row.
    @Test func givenTranscriptFeed_whenWorkingRowTurns_thenReportsCPU() async throws {
        try await profile(.workingRow, gate: "HARFLOW_ACTIVITY_CPU_WORKING_ROW_SECONDS")
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
        let indicator = indicatorDescription(source: source, owner: owner)
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
        return "\(indicator) held_stream_cpu_cores=\(cpuRate([holdStart, holdEnd])) "
            + "finished_idle_cpu_cores=\(cpuRate([idleStart, idleEnd]))"
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
            if tick == 0 { try await requireIndicator(source.variant, host: host, reduceMotion: reduceMotion) }
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
        let tail = source.showsLiveStep ? ActivityFeedTail(liveStep: LiveStep(rows: [], isRunning: true)) : ActivityFeedTail()
        let presentation: ActivityFeedTailPresentation = source.showsLiveStep
            ? .standard(.init(liveStep: .init(text: "Thinking…", indicator: .singleDot))) : .absent
        return ActivityFeedView(rows: source.rows, activitySnapshot: source.snapshot, start: nil, history: EventHistoryState(),
                                isLoading: false, tailValue: tail, style: source.variant == .workingRow ? .transcript : .standard,
                                state: state, onLoadMore: nil, tailPresentation: presentation)
    }

    /// Fails unless the variant's indicator is mounted, and moving unless the variant pauses it, before any measurement: a
    /// profile of a feed without its indicator would report a number that means nothing.
    private func requireIndicator(_ variant: CPUProfileVariant, host: NSView, reduceMotion: Bool?) async throws {
        let paused = reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        switch variant {
        case .fixedRow, .noCaretAnimation, .prebuiltSnapshots, .append, .appendNoCaretAnimation, .rootSizingOff:
            await waitUntil(timeout: 10) { LayerMotionProbe.views(LayerCaretView.self, in: host).count == 1 }
            let caret = try #require(LayerMotionProbe.views(LayerCaretView.self, in: host).first, "\(variant): the streaming caret must be mounted")
            await waitUntil(timeout: 5) { caret.isMotionInstalled == !paused }
            try #require(caret.isMotionInstalled == !paused, "\(variant): the caret must \(paused ? "not " : "")animate")
        case .liveTool:
            await waitUntil(timeout: 10) { !LayerMotionProbe.views(LayerSpinnerView.self, in: host).isEmpty }
            let spinner = try #require(LayerMotionProbe.views(LayerSpinnerView.self, in: host).first, "liveTool: the pending tool spinner must be mounted")
            await waitUntil(timeout: 5) { spinner.isMotionInstalled == !paused }
            try #require(spinner.isMotionInstalled == !paused && spinner.spec.diameter == HfRadius.Metrics.spacing12, "liveTool: spinner state")
        case .liveStepPulse:
            await waitUntil(timeout: 10) { LayerMotionProbe.views(LayerPulseDotView.self, in: host).count == 1 }
            let dot = try #require(LayerMotionProbe.views(LayerPulseDotView.self, in: host).first, "liveStepPulse: the pulse dot must be mounted")
            await waitUntil(timeout: 5) { dot.isMotionInstalled == !paused }
            try #require(dot.isMotionInstalled == !paused, "liveStepPulse: the dot must \(paused ? "not " : "")animate")
        case .workingRow:
            await waitUntil(timeout: 10) { LayerMotionProbe.views(LayerSpinnerView.self, in: host).count == 1 }
            let glyph = try #require(LayerMotionProbe.views(LayerSpinnerView.self, in: host).first, "workingRow: the working glyph must be mounted")
            await waitUntil(timeout: 5) { glyph.isMotionInstalled == !paused }
            try #require(glyph.spec.margin == TaskScreenStyle.Working.glyphMargin && glyph.isMotionInstalled == !paused, "workingRow: glyph state")
        }
    }

    /// Which running indicator the committed feed model carries while held.
    private func indicatorDescription(source: CPUProfileSource, owner: ActivityFeedNativeList.Coordinator) -> String {
        let pendingTool: Bool = if case .single(let row, _) = owner.model?.shownRows.last, case .item(let item) = row.kind,
                                   case .tool(_, nil) = item.body { row.live } else { false }
        let liveStep: Bool = if case .standard(let standard) = owner.model?.tailPresentation { standard.liveStep != nil } else { false }
        return "pending_tool=\(pendingTool) live_step=\(liveStep) style=\(owner.model?.style ?? .standard)"
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
    case liveTool
    case liveStepPulse
    case workingRow
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
    /// Whether the feed's tail shows the live step line (the standard pulse or the transcript working row).
    private(set) var showsLiveStep: Bool
    private var cycle: [([ActivityRow], ActivityFeedSnapshot)] = []

    init(variant: CPUProfileVariant) {
        self.variant = variant
        self.rows = (0 ..< Self.retained).map { index in
            ActivityRow.single(ActivityFixture.text(index, "Synthetic retained message \(index). Selectable reading content.", task: "soak"))
        }
        if variant == .liveTool {
            rows[Self.retained - 1] = .single(ActivityFixture.tool(Self.retained - 1, task: "soak", category: "shell", command: "make test",
                                                                   resolved: false))
        }
        self.showsLiveStep = [.liveStepPulse, .workingRow].contains(variant)
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
        showsLiveStep = false
        rows[rows.count - 1] = variant == .liveTool
            ? .single(ActivityFixture.tool(rows.count - 1, task: "soak", category: "shell", command: "make test"))
            : .single(ActivityFixture.text(rows.count - 1, "Synthetic stream finished.", task: "soak"))
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
        case .liveTool:
            rows[rows.count - 2] = Self.settledRow(seq: Self.retained - 2, tick: tick)
        case .liveStepPulse, .workingRow:
            rows[rows.count - 1] = Self.settledRow(seq: Self.retained - 1, tick: tick)
        case .append, .appendNoCaretAnimation:
            let last = rows.count - 1
            rows[last] = .single(ActivityFixture.text(Self.retained - 1 + tick, "Synthetic finished message \(tick).", task: "soak"))
            rows.append(Self.streamingRow(seq: Self.retained + tick, tick: tick))
        }
        snapshot = ActivityFeedSnapshot.preparing(rows, previous: snapshot)
        return snapshot
    }

    private static func settledRow(seq: Int, tick: Int) -> ActivityRow {
        .single(ActivityFixture.text(seq, "Synthetic settled delta \(tick % 100). " + String(repeating: "bounded text ", count: tick % 8 + 1),
                                     task: "soak"))
    }

    private static func streamingRow(seq: Int, tick: Int) -> ActivityRow {
        .single(ActivityFixture.text(seq, "Synthetic streaming delta \(tick % 100). " + String(repeating: "bounded text ", count: tick % 8 + 1),
                                     task: "soak", streaming: true))
    }
}
