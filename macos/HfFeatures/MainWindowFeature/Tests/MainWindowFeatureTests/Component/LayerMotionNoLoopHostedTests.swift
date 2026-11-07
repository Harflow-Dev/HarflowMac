import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - OldTimelineCaret

/// Test-only copy of the caret as it was before the layer change: a 30 Hz `TimelineView` that
/// rewrites the glyph's opacity every tick. It exists only as the negative control.
private struct OldTimelineCaret: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { context in
            Text("\u{258D}")
                .font(.hf(.body, design: .monospaced))
                .foregroundStyle(Color.secondaryText)
                .opacity(0.6 + 0.4 * cos(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.2))
        }
    }
}

// MARK: - MiniFeed

/// A feed-shaped harness, built the way the activity feed is: a hosting view whose content is an
/// `NSViewRepresentable` scroll view over a table, each cell an `NSHostingView` with intrinsic-size
/// sizing. The last row carries the caret under test. The real feed cannot mount the old caret (the
/// product no longer contains it), so the negative control and the layer caret both run here.
private struct MiniFeed: NSViewRepresentable {
    enum Caret { case oldTimeline, layer }

    let caret: Caret

    func makeCoordinator() -> Coordinator { Coordinator(caret: caret) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let table = NSTableView()
        table.headerView = nil
        table.style = .plain
        table.usesAutomaticRowHeights = false
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mini")))
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        return scroll
    }

    func updateNSView(_: NSScrollView, context _: Context) {}

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let caret: Caret
        init(caret: Caret) { self.caret = caret }

        func numberOfRows(in _: NSTableView) -> Int { 12 }
        func tableView(_: NSTableView, heightOfRow _: Int) -> CGFloat { 44 }

        func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
            let cell = NSTableCellView(frame: CGRect(x: 0, y: 0, width: 400, height: 44))
            let host = NSHostingView(rootView: MiniRow(isLast: row == 11, caret: caret))
            host.sizingOptions = [.intrinsicContentSize]
            host.autoresizingMask = [.width, .height]
            host.frame = cell.bounds
            cell.addSubview(host)
            return cell
        }
    }
}

private struct MiniRow: View {
    let isLast: Bool
    let caret: MiniFeed.Caret

    var body: some View {
        Text("Synthetic reply row with selectable reading content.")
            .font(.hf(.reading))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 16)
            .overlay(alignment: .bottomLeading) {
                if isLast {
                    switch caret {
                    case .oldTimeline: OldTimelineCaret()
                    case .layer: StreamingCaretLayer(blinks: true)
                    }
                }
            }
            .padding(.horizontal, 12)
    }
}

// MARK: - LayerMotionNoLoopHostedTests

/// The streaming caret must not keep the feed's SwiftUI graph pending. With the 30 Hz `TimelineView`
/// caret each pending update climbed to the feed's platform host, which re-ran `fittingSize` over the
/// whole table thousands of times a second. These tests count the relevant layout calls over a
/// two-second hold with no ticks.
@MainActor @Suite(.serialized) struct LayerMotionNoLoopHostedTests {
    private static let hold: TimeInterval = 2
    /// Upper bound on counted calls over the hold with the layer caret (zero measured).
    private static let quietLimit = 5
    /// The old caret must show the loop: at least this many counted calls over the hold (about 4,800
    /// measured in the mini harness; thousands per second in the real feed).
    private static let loopFloor = 500
    /// ... and at least this many root `fittingSize` calls specifically (241 to 484 measured).
    private static let fittingFloor = 100

    /// An intentional measurement window: the run loop spins for `seconds` with nothing driving the
    /// feed, which is the quiet period under test. It is not a wait for a condition.
    private func observe(for seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        await waitUntil(timeout: seconds + 1) { Date() >= deadline }
    }

    /// Waits for the window to report visible, and records an issue when it never does. Occlusion is not
    /// a hard precondition elsewhere, but the presentation-opacity check below needs a live render tree.
    private func requireVisibleOcclusion(_ window: NSWindow, _ label: String) async {
        await waitUntil(timeout: 5) { window.occlusionState.contains(.visible) }
        if !window.occlusionState.contains(.visible) {
            Issue.record("\(label): occlusionState never reported visible (\(window.occlusionState.rawValue)); presentation opacity is not trustworthy")
        }
    }

    /// Counts over `hold` seconds, and the layer caret's presentation opacities sampled meanwhile.
    private func measure(root: NSView, caretLayer: @MainActor () -> CALayer?) async -> (LayerMotionLoopProbe.Counts, [Float]) {
        root.layoutSubtreeIfNeeded()
        await observe(for: 0.5)
        LayerMotionLoopProbe.resetBreakdown()
        let start = LayerMotionLoopProbe.snapshot
        LayerMotionLoopProbe.arm(true)
        var opacities: [Float] = []
        let deadline = Date().addingTimeInterval(Self.hold)
        while Date() < deadline {
            if let presentation = caretLayer()?.presentation() { opacities.append(presentation.opacity) }
            await observe(for: 0.05)
        }
        LayerMotionLoopProbe.arm(false)
        return (LayerMotionLoopProbe.snapshot - start, opacities)
    }

    private func install(on views: [NSView]) {
        var seen = Set<ObjectIdentifier>()
        for view in views where seen.insert(ObjectIdentifier(type(of: view))).inserted {
            LayerMotionLoopProbe.install(on: type(of: view))
        }
    }

    private func breakdownDescription() -> String {
        LayerMotionLoopProbe.breakdown.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }

    private func expectOpacityMoves(_ opacities: [Float], _ label: String) {
        #expect(opacities.count >= 20, "\(label): too few presentation samples (\(opacities.count))")
        let spread = (opacities.max() ?? 0) - (opacities.min() ?? 0)
        #expect(spread > 0.2, "\(label): presentation opacity should sweep the blink range, spread \(spread)")
    }

    // MARK: Real feed

    @Test func givenStreamingFeedWithLayerCaret_whenTicksAreHeldForTwoSeconds_thenNoLayoutLoopRuns() async throws {
        // given
        _ = NSApplication.shared
        defer { LayerMotionLoopProbe.uninstall() }
        let rows = (0 ..< 40).map { index in
            ActivityRow.single(ActivityFixture.text(index, "Synthetic retained message \(index). Selectable reading content.",
                                                    task: "loop", streaming: index == 39))
        }
        let state = ParallelColumnUIState()
        let feed = ActivityFeedView(rows: rows, activitySnapshot: ActivityFeedSnapshot.preparing(rows, previous: nil), start: nil,
                                    history: EventHistoryState(), isLoading: false, state: state, onLoadMore: nil)
        let host = NSHostingView(rootView: feed.environment(\.hfReduceMotionOverride, false))
        let window = activityMountedTestWindow(host, style: [.titled, .resizable])
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 30) { state.viewportPositioned }
        try #require(state.viewportPositioned, "the feed must position")
        let table = try #require(activityNativeDescendants(host).compactMap { $0 as? ActivityFeedNativeTableView }.first)
        let scroll = try #require(table.enclosingScrollView)
        activityNativeRevealBottom(scroll)
        await waitUntil { state.followLive.isFollowing }
        try #require(state.followLive.isFollowing, "the feed must follow the tail")
        await waitUntil { LayerMotionProbe.count(in: host) == 1 }
        let caret = try #require(LayerMotionProbe.views(LayerCaretView.self, in: host).first, "the streaming row's caret view must exist")
        try #require(caret.isMotionInstalled && LayerMotionProbe.hasAnimation(caret.layer), "the caret must carry its animation before measuring")
        let owner = try #require(table.owner)
        install(on: [host, try #require(scroll.superview)] + owner.cells.values.compactMap(\.host) + Array(owner.cells.values))
        await requireVisibleOcclusion(window, "real feed")
        // when
        #expect(window.isVisible, "the window must be visible")
        print("LAYER_MOTION_MEASURED real_feed occlusion=\(window.occlusionState.rawValue) visible=\(window.occlusionState.contains(.visible)) "
            + "cells=\(owner.cells.count)")
        let layer = caret.layer
        let (counts, opacities) = await measure(root: host) { layer }
        // then
        print("LAYER_MOTION_MEASURED real_feed_layer_caret hold=\(Self.hold)s \(counts) opacity_samples=\(opacities.count) "
            + "min=\(opacities.min() ?? -1) max=\(opacities.max() ?? -1) breakdown=[\(breakdownDescription())]")
        #expect(counts.total <= Self.quietLimit, "layer caret: \(counts)")
        #expect(counts.fittingSize <= Self.quietLimit, "root fittingSize: \(counts)")
        try #require(caret.isMotionInstalled && LayerMotionProbe.hasAnimation(caret.layer), "the caret must still carry its animation after the hold")
        #expect(LayerMotionProbe.count(in: host) == 1)
        #expect(window.isVisible)
        expectOpacityMoves(opacities, "real feed")
        // the probe counts at all: one forced layout pass over the same classes is seen
        LayerMotionLoopProbe.resetBreakdown()
        let before = LayerMotionLoopProbe.snapshot
        LayerMotionLoopProbe.arm(true)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        for cell in owner.cells.values {
            cell.host?.needsLayout = true
            cell.layoutSubtreeIfNeeded()
        }
        LayerMotionLoopProbe.arm(false)
        let forced = LayerMotionLoopProbe.snapshot - before
        print("LAYER_MOTION_MEASURED real_feed_probe_sanity \(forced) breakdown=[\(breakdownDescription())]")
        #expect(forced.total > 0, "the probe must count a forced pass, or the quiet result above proves nothing")
        #expect(forced.fittingSize > 0, "the forced pass includes a root fittingSize")
    }

    // MARK: Negative control

    @Test func givenMiniFeedWithOldTimelineCaret_whenTicksAreHeldForTwoSeconds_thenTheLoopIsVisibleToTheProbe() async throws {
        // given
        let caret = MiniFeed.Caret.oldTimeline
        // when
        let result = try await runMini(caret)
        // then: the probe sees the loop, so a quiet result for the layer caret means something.
        #expect(result.counts.total >= Self.loopFloor, "old caret must show the loop: \(result.counts)")
        #expect(result.counts.fittingSize >= Self.fittingFloor, "old caret must show the fittingSize re-run: \(result.counts)")
        #expect(result.visible, "the window must be visible")
    }

    @Test func givenMiniFeedWithLayerCaret_whenTicksAreHeldForTwoSeconds_thenTheSameHarnessIsQuiet() async throws {
        // given
        let caret = MiniFeed.Caret.layer
        // when
        let result = try await runMini(caret)
        // then
        #expect(result.counts.total <= Self.quietLimit, "layer caret in the mini harness: \(result.counts)")
        #expect(result.counts.fittingSize <= Self.quietLimit, "layer caret in the mini harness: \(result.counts)")
        #expect(result.visible, "the window must be visible")
    }

    private func runMini(_ caret: MiniFeed.Caret) async throws -> (counts: LayerMotionLoopProbe.Counts, visible: Bool, occlusion: UInt) {
        _ = NSApplication.shared
        defer { LayerMotionLoopProbe.uninstall() }
        let host = NSHostingView(rootView: MiniFeed(caret: caret))
        let window = activityMountedTestWindow(host, style: [.titled, .resizable])
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 10) { lastRowHost(in: host) != nil }
        let lastHost = try #require(lastRowHost(in: host), "the mini feed's cells must mount")
        let scroll = try #require(activityNativeDescendants(host).compactMap { $0 as? NSScrollView }.first)
        let table = try #require(scroll.documentView as? NSTableView)
        table.scrollRowToVisible(11)
        host.layoutSubtreeIfNeeded()
        var caretView: LayerCaretView?
        if caret == .layer {
            await waitUntil { LayerMotionProbe.count(in: host) == 1 }
            caretView = try #require(LayerMotionProbe.views(LayerCaretView.self, in: host).first, "the layer caret must exist")
            try #require(caretView?.isMotionInstalled == true && LayerMotionProbe.hasAnimation(caretView?.layer),
                         "the layer caret must carry its animation before measuring")
        }
        install(on: [host, try #require(scroll.superview), lastHost, table])
        install(on: activityNativeDescendants(host).filter { $0 is NSTableCellView })
        await requireVisibleOcclusion(window, "mini \(caret)")
        let layer = caretView?.layer
        print("LAYER_MOTION_MEASURED mini_\(caret) occlusion=\(window.occlusionState.rawValue) visible=\(window.isVisible)")
        let (counts, opacities) = await measure(root: host) { layer }
        print("LAYER_MOTION_MEASURED mini_\(caret) hold=\(Self.hold)s \(counts) opacity_samples=\(opacities.count) breakdown=[\(breakdownDescription())]")
        if caret == .layer {
            try #require(caretView?.isMotionInstalled == true && LayerMotionProbe.hasAnimation(caretView?.layer),
                         "the layer caret must still carry its animation after the hold")
            expectOpacityMoves(opacities, "mini layer")
        }
        return (counts, window.isVisible, window.occlusionState.rawValue)
    }

    private func lastRowHost(in host: NSView) -> NSView? {
        activityNativeDescendants(host).first { view in
            NSStringFromClass(type(of: view)).contains("NSHostingView") && view !== host
                && NSStringFromClass(type(of: view)).contains("MiniRow")
        }
    }
}
