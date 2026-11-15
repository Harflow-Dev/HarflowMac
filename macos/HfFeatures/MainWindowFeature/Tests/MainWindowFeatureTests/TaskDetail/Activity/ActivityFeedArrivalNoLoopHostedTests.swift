import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - MiniArrivalModel

/// What the harness table shows: a growing row count and the arm under test.
@MainActor private final class MiniArrivalModel {
    enum Arm: CustomStringConvertible {
        /// The row root applies the SwiftUI `.hfFadeIn(animate: true)`: the retired arrival.
        case swiftUIFade
        /// The cell host's layer gets the production Core Animation fade.
        case layerFade

        var description: String { self == .swiftUIFade ? "swiftUIFade" : "layerFade" }
    }

    static let initialRows = 12

    let arm: Arm
    var count = MiniArrivalModel.initialRows
    weak var table: NSTableView?
    /// Hosts that received the production layer fade (the layer arm must attach one per appended row).
    var layerFadesAttached = 0

    init(arm: Arm) { self.arm = arm }

    func append() {
        guard let table else { return }
        count += 1
        table.insertRows(at: IndexSet(integer: count - 1), withAnimation: [])
        table.scrollRowToVisible(count - 1)
    }
}

// MARK: - MiniArrivalFeed

/// A feed-shaped harness built the way the activity feed is: a hosting view whose content is an
/// `NSViewRepresentable` scroll view over a table, each cell an `NSHostingView` with intrinsic-size
/// sizing. Rows appended after the first twelve fade in through the arm under test. The real feed
/// cannot mount the retired SwiftUI fade (the product no longer contains it), so both arms run here.
private struct MiniArrivalFeed: NSViewRepresentable {
    let model: MiniArrivalModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

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
        model.table = table
        return scroll
    }

    func updateNSView(_: NSScrollView, context _: Context) {}

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let model: MiniArrivalModel
        init(model: MiniArrivalModel) { self.model = model }

        func numberOfRows(in _: NSTableView) -> Int { model.count }
        func tableView(_: NSTableView, heightOfRow _: Int) -> CGFloat { 44 }

        func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
            let arrives = row >= MiniArrivalModel.initialRows
            let cell = NSTableCellView(frame: CGRect(x: 0, y: 0, width: 400, height: 44))
            let host = NSHostingView(rootView: MiniArrivalRow(index: row, swiftUIFade: arrives && model.arm == .swiftUIFade))
            host.sizingOptions = [.intrinsicContentSize]
            host.autoresizingMask = [.width, .height]
            host.frame = cell.bounds
            cell.addSubview(host)
            if arrives, model.arm == .layerFade, let layer = host.layer {
                ActivityFeedNativeCell.addArrivalFade(to: layer)
                model.layerFadesAttached += 1
            }
            return cell
        }
    }
}

private struct MiniArrivalRow: View {
    let index: Int
    let swiftUIFade: Bool

    var body: some View {
        Text("Synthetic arrival row \(index) with selectable reading content.")
            .font(.hf(.reading))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 16)
            .hfFadeIn(animate: swiftUIFade)
            .padding(.horizontal, 12)
    }
}

// MARK: - ActivityFeedArrivalNoLoopHostedTests

/// The arrival fade must not keep the feed's SwiftUI graph pending. With the SwiftUI fade each pending
/// update climbed to the feed's platform host, which re-ran `fittingSize` over the whole table for the
/// animation's duration. These tests count the probe's calls over a run of appends, each followed by the
/// fade duration plus a settle window, for the retired fade (negative control) and the layer fade.
///
/// Measured in a debug build, hosted, with ten appends at 0.25 s each: the thresholds below record the
/// numbers they were set from; only `fittingSize` gates.
@MainActor @Suite(.serialized) struct ActivityFeedArrivalNoLoopHostedTests {
    private static let appends = 10
    /// One append every 0.25 s: the arrival (0.18 s) plus a settle window, the same for every arm.
    private static let interval: TimeInterval = 0.25

    /// Upper bound on root `fittingSize` calls per run with the layer fade in the mini harness (10
    /// measured, one per append). Only `fittingSize` gates: the total of counted calls varies with the
    /// machine and the window state, so it is printed as a diagnostic.
    private static let quietFittingLimit = 40
    /// The SwiftUI fade must show the loop: at least this many root `fittingSize` calls per run (250
    /// measured with a visible window against 10 for the layer arm; an earlier run read about 6,750).
    private static let fittingFloor = 100
    /// Real feed: root `fittingSize` calls per append (4 measured over ten appends; the earlier whole-feed
    /// profile with a faster cadence read about 8 per append, so this leaves room above both and sits far
    /// below the 543 per append of the SwiftUI fade).
    private static let realFittingPerAppendLimit = 12

    private func observe(for seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        await waitUntil(timeout: seconds + 1) { Date() >= deadline }
    }

    private func requireVisibleOcclusion(_ window: NSWindow, _ label: String) async {
        await waitUntil(timeout: 5) { window.occlusionState.contains(.visible) }
        if !window.occlusionState.contains(.visible) {
            Issue.record("\(label): occlusionState never reported visible (\(window.occlusionState.rawValue))")
        }
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

    /// Counts over `appends` appends: the probe is armed before each one and observes the arrival plus
    /// the settle window. `append` performs one append.
    private func measure(root: NSView, append: () async -> Void) async -> LayerMotionLoopProbe.Counts {
        root.layoutSubtreeIfNeeded()
        await observe(for: 0.5)
        LayerMotionLoopProbe.resetBreakdown()
        let start = LayerMotionLoopProbe.snapshot
        for _ in 0 ..< Self.appends {
            LayerMotionLoopProbe.arm(true)
            await append()
            await observe(for: Self.interval)
        }
        LayerMotionLoopProbe.arm(false)
        return LayerMotionLoopProbe.snapshot - start
    }

    // MARK: Mini harness, both arms

    @Test func givenMiniFeedWithSwiftUIFade_whenRowsAppend_thenTheLoopIsVisibleToTheProbe() async throws {
        // given / when
        let result = try await runMini(.swiftUIFade)
        // then: the probe sees the loop, so a quiet result for the layer fade means something.
        #expect(result.counts.fittingSize >= Self.fittingFloor, "SwiftUI fade must show the fittingSize re-run: \(result.counts)")
        #expect(result.visible, "the window must be visible")
    }

    @Test func givenMiniFeedWithLayerFade_whenRowsAppend_thenTheSameHarnessIsQuiet() async throws {
        // given / when
        let result = try await runMini(.layerFade)
        // then
        #expect(result.counts.fittingSize <= Self.quietFittingLimit, "layer fade in the mini harness: \(result.counts)")
        #expect(result.attached == Self.appends, "every appended row must have received the production layer fade")
        #expect(result.visible, "the window must be visible")
    }

    private func runMini(_ arm: MiniArrivalModel.Arm) async throws
        -> (counts: LayerMotionLoopProbe.Counts, visible: Bool, attached: Int) {
        _ = NSApplication.shared
        defer { LayerMotionLoopProbe.uninstall() }
        let model = MiniArrivalModel(arm: arm)
        let host = NSHostingView(rootView: MiniArrivalFeed(model: model))
        let window = activityMountedTestWindow(host, style: [.titled, .resizable])
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 10) { model.table?.view(atColumn: 0, row: 0, makeIfNecessary: false) != nil }
        let table = try #require(model.table, "the mini feed must mount")
        let scroll = try #require(table.enclosingScrollView)
        table.scrollRowToVisible(model.count - 1)
        host.layoutSubtreeIfNeeded()
        let views = activityNativeDescendants(host)
        install(on: [host, try #require(scroll.superview), table] + views.filter {
            let name = NSStringFromClass(type(of: $0))
            return name.contains("NSHostingView") || $0 is NSTableCellView
        })
        await requireVisibleOcclusion(window, "mini \(arm)")
        let counts = await measure(root: host) { model.append() }
        print("ARRIVAL_MEASURED mini_\(arm) appends=\(Self.appends) interval=\(Self.interval)s \(counts) "
            + "occlusion=\(window.occlusionState.rawValue) breakdown=[\(breakdownDescription())]")
        return (counts, window.isVisible, model.layerFadesAttached)
    }

    // MARK: Real feed

    @Test func givenFollowingFeed_whenRowsAppend_thenRootFittingSizeStaysNearTheMeasuredPerAppendLevel() async throws {
        // given
        _ = NSApplication.shared
        defer { LayerMotionLoopProbe.uninstall() }
        _ = ActivityFeedArrivalFadeSpy.install
        let state = ParallelColumnUIState()
        let host = NSHostingView(rootView: AnyView(feed(1 ... 40, state: state)))
        let window = activityMountedTestWindow(host, style: [.titled, .resizable])
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 30) { state.viewportPositioned }
        try #require(state.viewportPositioned, "the feed must position")
        let table = try #require(activityNativeDescendants(host).compactMap { $0 as? ActivityFeedNativeTableView }.first)
        let scroll = try #require(table.enclosingScrollView)
        await waitUntil { state.followLive.isFollowing }
        try #require(state.followLive.isFollowing, "the feed must follow the tail")
        let owner = try #require(table.owner)
        install(on: [host, try #require(scroll.superview)] + owner.cells.values.compactMap(\.host) + Array(owner.cells.values)
            + [owner.measurementHost].compactMap(\.self))
        await requireVisibleOcclusion(window, "real feed")
        var last = 40
        ActivityFeedArrivalFadeSpy.reset()
        // when
        let counts = await measure(root: host) {
            last += 1
            host.rootView = AnyView(feed(1 ... last, state: state))
        }
        await waitUntil(timeout: 5) { owner.entries.contains { $0.id == "ti-\(last)" } }
        // then
        let perAppend = Double(counts.fittingSize) / Double(Self.appends)
        print("ARRIVAL_MEASURED real_feed appends=\(Self.appends) \(counts) fittingSize_per_append=\(perAppend) "
            + "occlusion=\(window.occlusionState.rawValue) breakdown=[\(breakdownDescription())]")
        try #require(owner.entries.contains { $0.id == "ti-\(last)" }, "every append must reach the table")
        #expect(ActivityFeedArrivalFadeSpy.total == Self.appends, "each appended row must play exactly one arrival fade")
        #expect(perAppend <= Double(Self.realFittingPerAppendLimit), "root fittingSize per append: \(counts)")
        #expect(window.isVisible)
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
        print("ARRIVAL_MEASURED real_feed_probe_sanity \(forced)")
        #expect(forced.total > 0, "the probe must count a forced pass, or the result above proves nothing")
        #expect(forced.fittingSize > 0, "the forced pass includes a root fittingSize")
    }

    private func feed(_ range: ClosedRange<Int>, state: ParallelColumnUIState) -> some View {
        let rows = range.map { index in
            ActivityRow.single(ConversationTimelineRow(
                id: "ti-\(index)", taskID: "arrival-task", timestamp: nil,
                kind: .item(PreviewFixtures.textItem(
                    String(repeating: "Row \(index) wraps across the native reading width. ", count: 4), seq: index)),
                live: false))
        }
        return ActivityFeedView(rows: rows, start: nil, history: EventHistoryState(hasMore: true), isLoading: false,
                                horizontalPadding: 12, state: state, onLoadMore: nil)
            .environment(\.hfReduceMotionOverride, true)
            .environment(\.dynamicTypeSize, .large)
            .frame(width: 420, height: 450)
    }
}
