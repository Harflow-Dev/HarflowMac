import AppKit
import Combine
import HfCommon
import HfCommonTestMock
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import Mockable
@testable import MonitorCore
import ObjectiveC
import SwiftUI
import Testing

// MARK: - StyleReloadSpy

/// Counts `NSTableView.reloadData` per table instance. It wraps whatever implementation is
/// installed, so it coexists with the spy of `ActivityFeedNativeTailInsertHostedTests`; counts are
/// keyed by table identity.
private enum StyleReloadSpy {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var counts: [ObjectIdentifier: Int] = [:]

    static let install: Void = {
        let selector = Selector(("reloadData"))
        guard let method = class_getInstanceMethod(NSTableView.self, selector) else { return }
        typealias Original = @convention(c) (AnyObject, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let block: @convention(block) (AnyObject) -> Void = { table in
            lock.lock()
            counts[ObjectIdentifier(table), default: 0] += 1
            lock.unlock()
            original(table, selector)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }()

    static func count(_ table: AnyObject) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[ObjectIdentifier(table)] ?? 0
    }
}

// MARK: - ActivityFeedTranscriptStyleHostedTests

/// Hosted behaviour of `ActivityFeedStyle.transcript`: the 760 column and 696 point measure, the
/// #44 sentinel and pinned bottom, live append without `reloadData`, a style change while reading,
/// measured against displayed heights, which surfaces mount which style, and the optional review
/// captures (`HARFLOW_M04_CAPTURE_DIR`).
@MainActor @Suite(.serialized) struct ActivityFeedTranscriptStyleHostedTests {
    @MainActor private struct Mounted {
        let state: ParallelColumnUIState
        let host: NSHostingView<AnyView>
        let window: NSWindow
        let table: ActivityFeedNativeTableView
        let scroll: NSScrollView
        let owner: ActivityFeedNativeList.Coordinator

        func close() {
            window.contentView = nil
            window.close()
        }

        func update(_ view: some View) { host.rootView = AnyView(view) }
        func index(of id: String) -> Int? { owner.entries.firstIndex { $0.id == id } }
        func relativeOffset(of id: String) -> CGFloat? {
            index(of: id).map { table.rect(ofRow: $0).minY - scroll.documentVisibleRect.minY }
        }
    }

    static let taskID = "style-task"

    // MARK: Column and measure

    @Test func givenTranscriptPaneAtWidth1100_whenMounted_thenColumnIs760CenteredWithA696PointMeasure() async throws {
        // given
        #expect(HfRadius.Metrics.taskColumnMaxWidth == 760)
        let mounted = try await mount(model: Self.timelineModel(Self.parityRows(live: false)), style: .transcript,
                                      size: NSSize(width: 1100, height: 700))
        defer { mounted.close() }
        // when — the turn separator's two rules span the full measure, so their ink is the measure.
        let column = mounted.scroll.convert(mounted.scroll.bounds, to: mounted.host)
        let separator = try await reveal("sep:" + Self.taskID, in: mounted)
        await DisplayFrames.waitForPresentedFrame()
        let root = try #require(separator.host?.rootView)
        let cellFrame = separator.convert(separator.bounds, to: mounted.host)
        let ink = try inkBounds(in: mounted.host, band: cellFrame)
        // then
        #expect(abs(column.width - 760) < 1, "column width \(column.width)")
        #expect(abs(column.minX - 170) < 1 && abs(mounted.host.bounds.maxX - column.maxX - 170) < 1, "column x \(column.minX)")
        #expect(root.style == .transcript)
        #expect(root.horizontalPadding == 32)
        // The approved text measure is 696 (760 less 2 x 32), centred: equal gaps either side in the column.
        let textLeft = ink.minX
        let textRight = ink.maxX
        let leftGap = textLeft - column.minX
        let rightGap = column.maxX - textRight
        #expect(abs((textRight - textLeft) - 696) < 2, "rendered measure \(textRight - textLeft)")
        #expect(abs(leftGap - 32) < 2 && abs(rightGap - 32) < 2, "gaps \(leftGap) / \(rightGap)")
        #expect(abs(leftGap - rightGap) <= 2, "gaps \(leftGap) / \(rightGap)")
    }

    @Test func givenStandardPaneAtWidth1100_whenMounted_thenPaddingIsStillTwentyFour() async throws {
        // given / when
        let mounted = try await mount(1 ... 30, style: .standard, size: NSSize(width: 1100, height: 700))
        defer { mounted.close() }
        let cell = try #require(realizedCells(mounted).first?.cell)
        let root = try #require(cell.host?.rootView)
        // then — guard: the standard style keeps 24 and the same 760 column.
        #expect(root.style == .standard)
        #expect(root.horizontalPadding == 24)
        // Guard: today's standard row width is the 760 column less the table's intercell spacing.
        #expect(abs((root.availableWidth ?? 0) - (760 - ActivityFeedNativeListMetrics.horizontalIntercellSpacing)) < 1.5)
        #expect(mounted.owner.model?.style == .standard)
    }

    // MARK: Sentinel and following

    @Test func givenFollowingTranscriptFeed_whenRowAppended_thenNoReloadSentinelIsSixteenAndBottomIsPinned() async throws {
        // given
        let mounted = try await mount(1 ... 40, style: .transcript, size: NSSize(width: 1100, height: 500))
        defer { mounted.close() }
        try #require(mounted.state.followLive.isFollowing)
        let reloads = StyleReloadSpy.count(mounted.table)
        // when
        mounted.update(pane(1 ... 41, state: mounted.state, style: .transcript, size: NSSize(width: 1100, height: 500)))
        await waitUntil(timeout: 5) { mounted.index(of: "ti-41") != nil }
        // then
        try #require(mounted.index(of: "ti-41") != nil)
        #expect(StyleReloadSpy.count(mounted.table) == reloads, "live append must not call reloadData")
        #expect(mounted.table.numberOfRows == mounted.owner.entries.count)
        let sentinel = try #require(mounted.index(of: "activity-feed-bottom"))
        #expect(sentinel == mounted.owner.entries.count - 1)
        #expect(abs(mounted.table.rect(ofRow: sentinel).height - 16) < 2)
        #expect(abs(mounted.scroll.documentVisibleRect.maxY - mounted.table.rect(ofRow: sentinel).maxY) < 3)
        #expect(mounted.state.followLive.isFollowing)
    }

    // MARK: Style change while reading

    @Test func givenPausedReader_whenStyleChangesFromStandardToTranscript_thenAnchorKeepsItsPlace() async throws {
        // given — the group promotion case: a reader paused mid-feed, the mount flips style.
        let size = NSSize(width: 1000, height: 500)
        let mounted = try await mount(1 ... 40, style: .standard, size: size)
        defer { mounted.close() }
        let paused = try #require(mounted.index(of: "ti-20"))
        activityNativeTestScroll(mounted.scroll, to: mounted.table.rect(ofRow: paused).minY + 30)
        await waitUntil(timeout: 3) { !mounted.state.followLive.isFollowing && mounted.state.anchor != nil }
        try #require(!mounted.state.followLive.isFollowing)
        let anchor = try #require(mounted.state.anchor?.id)
        let before = try #require(mounted.relativeOffset(of: anchor))
        let height = mounted.table.rect(ofRow: try #require(mounted.index(of: "ti-3"))).height
        // when
        mounted.update(pane(1 ... 40, state: mounted.state, style: .transcript, size: size))
        await waitUntil(timeout: 5) { mounted.owner.model?.style == .transcript }
        await waitUntil(timeout: 3) {
            mounted.table.rect(ofRow: mounted.index(of: "ti-3") ?? 0).height != height
        }
        // then — the remeasurement really happened: the 696 point measure and the 16 point gap change the row.
        try #require(mounted.owner.model?.style == .transcript)
        let remeasured = mounted.table.rect(ofRow: try #require(mounted.index(of: "ti-3"))).height
        try #require(remeasured != height, "row height stayed \(height): the style change never remeasured")
        let after = try #require(mounted.relativeOffset(of: anchor))
        #expect(abs(after - before) < 3, "anchor \(anchor) moved by \(after - before)")
        #expect(!mounted.state.followLive.isFollowing)
        #expect(mounted.table.numberOfRows == mounted.owner.entries.count)
    }

    // MARK: Measured against displayed

    @Test(arguments: [ActivityFeedStyle.standard, .transcript])
    func givenStyledPane_whenEveryRowKindIsRealized_thenEachSlotMatchesTheDisplayedHostHeightCollapsedAndExpanded(
        style: ActivityFeedStyle
    ) async throws {
        // given / when
        let collapsed = try await displayedParity(style: style, expanded: false)
        let expanded = try await displayedParity(style: style, expanded: true)
        // then — every kind of entry was compared, and expanding really changed the expandable ones.
        let ids = Set(collapsed.keys)
        for id in ["activity-feed-header", Self.rowID(0), Self.rowID(2), "sep:" + Self.taskID, Self.rowID(5),
                   Self.rowID(6), Self.rowID(7), "activity-feed-tail", "activity-feed-bottom"] {
            #expect(ids.contains(id), "\(style) never compared \(id)")
        }
        #expect((expanded[Self.rowID(2)] ?? 0) > (collapsed[Self.rowID(2)] ?? 0) + 20, "\(style) expanded group")
        #expect((expanded[Self.rowID(5)] ?? 0) > (collapsed[Self.rowID(5)] ?? 0) + 20, "\(style) expanded edit")
        #expect((expanded[Self.rowID(7)] ?? 0) > (collapsed[Self.rowID(7)] ?? 0) + 10, "\(style) expanded shell group")
    }

    /// Mounts the mixed fixture, reveals every entry in turn and compares its table slot with the height the
    /// displayed host itself asks for (`fittingSize` of the realized cell's hosting view at its own width),
    /// returning the slot heights by entry id.
    private func displayedParity(style: ActivityFeedStyle, expanded: Bool) async throws -> [String: CGFloat] {
        let state = ParallelColumnUIState()
        let model = Self.timelineModel(Self.parityRows(live: true))
        if expanded {
            state.expandedGroups = Set(model.activityRows.compactMap(\.group).map(\.id))
            state.disclosures.expandedTools = [Self.taskID + ":c-edit-a", Self.taskID + ":c-write", Self.taskID + ":c-run"]
        }
        let mounted = try await mount(model: model, style: style, size: NSSize(width: 1000, height: 600), state: state)
        defer { mounted.close() }
        var heights: [String: CGFloat] = [:]
        for entry in mounted.owner.entries {
            let cell = try await reveal(entry.id, in: mounted)
            let host = try #require(cell.host)
            host.layoutSubtreeIfNeeded()
            let slot = mounted.table.rect(ofRow: try #require(mounted.index(of: entry.id))).height
            let displayed = host.fittingSize.height
            #expect(abs(slot - displayed) < 1, "\(style) expanded=\(expanded) \(entry.id): slot \(slot) vs displayed \(displayed)")
            heights[entry.id] = slot
        }
        return heights
    }

    @Test(arguments: [ActivityFeedStyle.standard, .transcript])
    func givenStyledPane_whenAToolRowIsExpandedInPlace_thenItsSlotGrowsToTheDisplayedHeight(style: ActivityFeedStyle) async throws {
        // given
        let state = ParallelColumnUIState()
        let mounted = try await mount(model: Self.timelineModel(Self.parityRows(live: false)), style: style,
                                      size: NSSize(width: 1000, height: 700), state: state)
        defer { mounted.close() }
        let id = Self.rowID(6)
        let cell = try await reveal(id, in: mounted)
        let before = mounted.table.rect(ofRow: try #require(mounted.index(of: id))).height
        // when — the disclosure the tool row's own toggle writes.
        state.disclosures.expandedTools.insert(Self.taskID + ":c-write")
        await waitUntil(timeout: 5) { mounted.table.rect(ofRow: mounted.index(of: id) ?? 0).height > before + 5 }
        // then
        let after = mounted.table.rect(ofRow: try #require(mounted.index(of: id))).height
        try #require(after > before + 5, "\(style) tool row stayed \(before)")
        let host = try #require(cell.host)
        host.layoutSubtreeIfNeeded()
        #expect(abs(after - host.fittingSize.height) < 1, "\(style) slot \(after) vs displayed \(host.fittingSize.height)")
        let rowIndex = try #require(mounted.index(of: id))
        let fresh = try #require(mounted.owner.measure(mounted.owner.boxes[rowIndex], width: mounted.owner.currentWidth))
        #expect(abs(after - fresh) < 1)
    }

    // MARK: Tool row details

    @Test(arguments: [(ActivityFeedStyle.transcript, false, false), (.transcript, true, true),
                      (.standard, false, true), (.standard, true, true)])
    func givenEditRowsWithAndWithoutADiff_whenMounted_thenThePreviewShowsOnlyWhereTheStyleAllows(
        style: ActivityFeedStyle, expanded: Bool, showsPreview: Bool
    ) async throws {
        // given — two edits identical but for the diff payload.
        let state = ParallelColumnUIState()
        if expanded { state.disclosures.expandedTools = [Self.taskID + ":c-with-diff", Self.taskID + ":c-no-diff"] }
        func edit(_ seq: Int, _ id: String, diff: Bool) -> ConversationTimelineRow {
            ActivityFixture.row(seq, task: Self.taskID, live: false, .tool(
                TaskEvent.ToolCall(callID: id, tool: "Edit", category: "edit", inputPreview: "/repo/a.swift", path: "/repo/a.swift",
                                   command: nil, editOld: diff ? "let a = 1\nlet b = 2" : nil,
                                   editNew: diff ? "let a = 10\nlet b = 20" : nil),
                TaskEvent.ToolResult(callID: id, ok: true, outputTail: "ok", exitCode: nil)))
        }
        let rows = [ActivityFixture.text(0, "Intro", task: Self.taskID), edit(1, "c-with-diff", diff: true),
                    edit(2, "c-no-diff", diff: false), ActivityFixture.text(3, "Outro", task: Self.taskID)]
        // when
        let mounted = try await mount(model: Self.timelineModel(rows), style: style, size: NSSize(width: 1000, height: 900), state: state)
        defer { mounted.close() }
        // then
        let withDiff = mounted.table.rect(ofRow: try #require(mounted.index(of: Self.rowID(1)))).height
        let without = mounted.table.rect(ofRow: try #require(mounted.index(of: Self.rowID(2)))).height
        if showsPreview {
            #expect(withDiff > without + 20, "\(style) expanded=\(expanded): with \(withDiff) without \(without)")
        } else {
            #expect(abs(withDiff - without) < 1, "\(style) expanded=\(expanded): with \(withDiff) without \(without)")
        }
    }

    @Test(arguments: [ActivityFeedStyle.standard, .transcript])
    func givenToolGroupHead_whenTheTimeRangeVaries_thenOnlyTheStandardHeadShowsIt(style: ActivityFeedStyle) throws {
        // given — two groups with the same wording; one spans two instants, one a single instant.
        func group(_ second: TimeInterval) throws -> ToolGroup {
            let rows = [ActivityFixture.tool(1, task: Self.taskID, path: "/a.swift", at: 1),
                        ActivityFixture.tool(2, task: Self.taskID, path: "/b.swift", at: second)]
            return try #require(ActivityRowsBuilder.build(from: rows).first?.group)
        }
        let spanning = try group(3_000)
        let single = try group(1)
        try #require(spanning.summary == single.summary && spanning.subtitle == single.subtitle)
        try #require(spanning.timeRangeText(start: ActivityFixture.base) != single.timeRangeText(start: ActivityFixture.base))
        func width(_ group: ToolGroup) -> CGFloat {
            NSHostingView(rootView: ToolGroupCardView(group: group, start: ActivityFixture.base, isExpanded: false, onToggle: {})
                .environment(\.activityFeedStyle, style))
.fittingSize
.width
        }
        // when
        let spanningWidth = width(spanning)
        let singleWidth = width(single)
        // then
        if style.isTranscript {
            #expect(abs(spanningWidth - singleWidth) < 0.5, "transcript head width depends on the time range: \(spanningWidth) / \(singleWidth)")
        } else {
            #expect(spanningWidth > singleWidth + 5, "standard head hides the time range: \(spanningWidth) / \(singleWidth)")
        }
    }

    // MARK: First row after a window slide

    @Test func givenFullTranscriptWindow_whenItSlidesByOneRow_thenTheSurvivorBecomesFirstAndRemeasuresThroughItsRevision() async throws {
        // given — 100 rows shown; history not exhausted, so no header.
        let size = NSSize(width: 1000, height: 600)
        let mounted = try await mount(1 ... 100, style: .transcript, size: size)
        defer { mounted.close() }
        let survivor = try #require(mounted.index(of: "ti-2"))
        let interior = mounted.table.rect(ofRow: survivor).height
        let revisionBefore = mounted.owner.boxes[survivor].revision
        // when — 101 rows exist, so the window shows rows 2 ... 101 and row 2 opens the feed.
        mounted.update(pane(1 ... 101, state: mounted.state, style: .transcript, size: size))
        await waitUntil(timeout: 8) { mounted.index(of: "ti-101") != nil }
        // then — 16 point gap becomes the 24 point opening padding, through a new box revision.
        try #require(mounted.index(of: "ti-2") == 0)
        try #require(mounted.owner.entries.count == 100 + 1)
        #expect(mounted.owner.boxes[0].revision == revisionBefore + 1, "the first-row spacing change skipped the revision compare")
        guard case .row(let first) = mounted.owner.entries[0] else {
            Issue.record("first entry is not a row")
            return
        }
        #expect(first.topSpacing == 24)
        #expect(abs((mounted.table.rect(ofRow: 0).height - interior) - 8) < 1.5)
        let cell = try await reveal("ti-2", in: mounted)
        let host = try #require(cell.host)
        host.layoutSubtreeIfNeeded()
        #expect(abs(mounted.table.rect(ofRow: 0).height - host.fittingSize.height) < 1)
    }

    // MARK: Pane background

    @Test(arguments: [false, true])
    func givenTaskDetail_whenRendered_thenTheTranscriptPaneIsThePageTokenAndTheStandardPaneIsNot(dark: Bool) async throws {
        // given — the token itself, rendered through the same pipeline, is the reference: the offscreen bitmap's
        // colour space shifts dark greys, so absolute values are not comparable but identical pipelines are.
        let reference = try await renderedPixels(dark: dark, style: nil)
        let transcript = try await renderedPixels(dark: dark, style: .transcript)
        let standard = try await renderedPixels(dark: dark, style: .standard)
        // then
        func close(_ lhs: [Int], _ rhs: [Int]) -> Bool { zip(lhs, rhs).allSatisfy { abs($0 - $1) <= 2 } }
        let want = try #require(reference.first)
        for sample in transcript { #expect(close(sample, want), "transcript pixel \(sample), want the page token \(want)") }
        for sample in standard { #expect(!close(sample, want), "standard pixel \(sample) is the page token \(want)") }
    }

    /// Pixels (RGB 0 ... 255) rendered at a margin point left of the reading column and a point inside it below the
    /// short reply. With `style == nil` it fills the pane with the `--bg` token instead and returns one pixel.
    private func renderedPixels(dark: Bool, style: ActivityFeedStyle?) async throws -> [[Int]] {
        _ = NSApplication.shared
        let mock = TaskDetailViewModelMock.finished()
        mock.timelineModel = Self.timelineModel([ActivityFixture.text(0, "A short reply.", task: Self.taskID)])
        let content = if let style {
            AnyView(TaskDetailView(mock, transcriptStyle: style).environment(\.hfReduceMotionOverride, true))
        } else {
            AnyView(TaskScreenStyle.Colors.pageBackground.color)
        }
        let host = NSHostingView(rootView: AnyView(content.preferredColorScheme(dark ? .dark : .light)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        var points = [CGPoint(x: 12, y: 400)]
        if style != nil {
            await waitUntil(timeout: 8) { Self.tables(host).first?.owner?.model != nil }
            let table = try #require(Self.tables(host).first)
            let scroll = try #require(table.enclosingScrollView)
            await waitUntil(timeout: 8) { host.layoutSubtreeIfNeeded(); return scroll.window != nil && scroll.bounds.height > 100 }
            host.layoutSubtreeIfNeeded()
            let feed = scroll.convert(scroll.bounds, to: host)
            points = [CGPoint(x: 12, y: feed.midY), CGPoint(x: feed.minX + 8, y: feed.maxY - 40)]
        }
        await DisplayFrames.waitForPresentedFrame()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        return try points.map { point in
            let color = try #require(bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.deviceRGB))
            return [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
        }
    }

    // MARK: Standard bubble guard

    @Test func givenStandardBubbleLayout_whenOfferedWideWidth_thenItKeepsSeventyFivePercentAndFourHundredTwentyCap() async throws {
        // given
        let defaults = PromptBubbleTrailingLayout()
        #expect(defaults.fraction == 0.75)
        #expect(defaults.cap == 420)
        // when
        let standard = await bubbleWidth(PromptBubbleTrailingLayout(), width: 1000)
        let narrow = await bubbleWidth(PromptBubbleTrailingLayout(), width: 400)
        let transcript = await bubbleWidth(PromptBubbleTrailingLayout(
            fraction: TaskScreenStyle.UserBubble.maxWidthFraction, cap: .infinity), width: 1000)
        // then
        #expect(abs(standard - 420) < 1, "standard bubble \(standard)")
        #expect(abs(narrow - 300) < 1, "narrow bubble \(narrow)")
        #expect(abs(transcript - 800) < 1, "transcript bubble \(transcript)")
    }

    // MARK: Helpers

    static func tables(_ view: NSView) -> [ActivityFeedNativeTableView] {
        activityNativeDescendants(view).compactMap { $0 as? ActivityFeedNativeTableView }
    }

    private func bubbleWidth(_ layout: PromptBubbleTrailingLayout, width: CGFloat) async -> CGFloat {
        let box = WidthBox()
        let host = NSHostingView(rootView: layout {
            Text(String(repeating: "wide ", count: 400))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { box.value = $0 }
        }.frame(width: width, height: 80))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 3) { host.layoutSubtreeIfNeeded(); return box.value > 0 }
        return box.value
    }

    private func realizedCells(_ mounted: Mounted) throws -> [(row: Int, cell: ActivityFeedNativeCell)] {
        let range = mounted.table.rows(in: mounted.table.visibleRect)
        var result: [(row: Int, cell: ActivityFeedNativeCell)] = []
        for row in range.location ..< range.location + range.length {
            if let cell = mounted.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ActivityFeedNativeCell,
               cell.host != nil {
                result.append((row, cell))
            }
        }
        try #require(!result.isEmpty, "no realized cells in the visible rect")
        return result
    }

    private func mount(_ range: ClosedRange<Int>, style: ActivityFeedStyle, size: NSSize) async throws -> Mounted {
        try await mount(model: Self.proseModel(range), style: style, size: size)
    }

    private func mount(model: TimelinePaneModel, style: ActivityFeedStyle, size: NSSize,
                       state: ParallelColumnUIState = ParallelColumnUIState()) async throws -> Mounted {
        _ = StyleReloadSpy.install
        _ = NSApplication.shared
        let host = NSHostingView(rootView: AnyView(pane(model, state: state, style: style, size: size)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(size)
        window.orderFront(nil)
        await waitUntil(timeout: 8) { state.viewportPositioned }
        let table = try #require(Self.tables(host).first)
        let scroll = try #require(table.enclosingScrollView)
        let owner = try #require(table.owner)
        try #require(StyleReloadSpy.count(table) > 0, "the reloadData spy is not counting")
        return Mounted(state: state, host: host, window: window, table: table, scroll: scroll, owner: owner)
    }

    private func pane(_ range: ClosedRange<Int>, state: ParallelColumnUIState, style: ActivityFeedStyle,
                      size: NSSize) -> some View {
        pane(Self.proseModel(range), state: state, style: style, size: size)
    }

    private func pane(_ model: TimelinePaneModel, state: ParallelColumnUIState, style: ActivityFeedStyle,
                      size: NSSize) -> some View {
        TimelinePaneView(model: model, state: state, style: style)
            .environment(\.hfReduceMotionOverride, true)
            .frame(width: size.width, height: size.height)
    }

    private static func proseModel(_ range: ClosedRange<Int>) -> TimelinePaneModel {
        let conversation = range.map { index in
            ConversationTimelineRow(
                id: "ti-\(index)", taskID: taskID, timestamp: nil,
                kind: .item(PreviewFixtures.textItem(
                    String(repeating: "Row \(index) wraps across the transcript reading width. ", count: 5), seq: index)),
                live: false)
        }
        let rows = conversation.map { ActivityRow.single($0, markdown: nil) }
        return TimelinePaneModel(
            stepCountText: nil, rows: conversation, activityRows: rows, start: nil, emptyText: nil, subTaskStrip: nil,
            isLoading: false, liveStep: nil, updateToken: ActivityUpdateToken(rows: conversation, liveStep: nil),
            history: EventHistoryState(hasMore: true))
    }

    // MARK: Realized cells and rendered ink

    private func cell(for id: String, in mounted: Mounted) -> ActivityFeedNativeCell? {
        guard let row = mounted.index(of: id) else { return nil }
        return mounted.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ActivityFeedNativeCell
    }

    /// Scrolls the entry to the top of the viewport (or as far as the document allows) and returns its realized cell.
    private func reveal(_ id: String, in mounted: Mounted) async throws -> ActivityFeedNativeCell {
        let row = try #require(mounted.index(of: id), "no entry \(id)")
        let top = mounted.table.rect(ofRow: row).minY
        let limit = max(0, mounted.table.bounds.maxY - mounted.scroll.contentView.bounds.height)
        activityNativeTestScroll(mounted.scroll, to: min(max(0, top), limit))
        await waitUntil(timeout: 3) { cell(for: id, in: mounted)?.host != nil }
        let found = try #require(cell(for: id, in: mounted), "entry \(id) was never realized")
        found.layoutSubtreeIfNeeded()
        return found
    }

    /// The horizontal extent, in `view`'s points, of what is rendered inside `band` that differs from the band's own
    /// background (read at its left edge): the outer window content is rendered because an individual
    /// cell host does not render on its own.
    private func inkBounds(in view: NSView, band: CGRect) throws -> (minX: CGFloat, maxX: CGFloat) {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        func components(_ x: Int, _ y: Int) -> [CGFloat] {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return [0, 0, 0, 0] }
            return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
        }
        var minX = Int.max
        var maxX = -1
        for y in Int(band.minY * scale) ..< Int(band.maxY * scale) {
            let background = components(0, y)
            for x in 0 ..< bitmap.pixelsWide where zip(components(x, y), background).contains(where: { abs($0 - $1) > 0.05 }) {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        try #require(maxX >= 0, "nothing rendered in the band")
        return (CGFloat(minX) / scale, CGFloat(maxX + 1) / scale)
    }

    private static func rowID(_ seq: Int) -> String { "\(taskID)#\(seq)" }

    // MARK: Synthetic content

    static func timelineModel(_ rows: [ConversationTimelineRow]) -> TimelinePaneModel {
        TimelinePaneModel(stepCountText: "\(rows.count) activity items", rows: rows, start: ActivityFixture.base, emptyText: nil,
                          subTaskStrip: nil, isLoading: false)
    }

    /// Every kind of feed entry: an initial prompt bubble, prose, a read group, a list, an edit with a diff, a write,
    /// a shell group with long output, a turn separator with a follow-up, closing prose and (live) a running tool for
    /// the working tail.
    private static func parityRows(live: Bool) -> [ConversationTimelineRow] {
        func toolRow(_ seq: Int, _ id: String, category: String, name: String, path: String? = nil, command: String? = nil,
                     old: String? = nil, new: String? = nil, output: String?, running: Bool = false) -> ConversationTimelineRow {
            let call = TaskEvent.ToolCall(callID: id, tool: name, category: category, inputPreview: command ?? path ?? name,
                                          path: path, command: command, editOld: old, editNew: new)
            let result = output.map { TaskEvent.ToolResult(callID: id, ok: true, outputTail: $0, exitCode: 0) }
            return ActivityFixture.row(seq, task: taskID, live: running, .tool(call, result))
        }
        let list = "Two changes follow:\n\n- move `notify_all()` inside the lock\n- re-check the free count"
        let longOutput = (1 ... 8).map { "output line \($0)" }.joined(separator: "\n")
        var rows = [
            ActivityFixture.message(0, "Find out why the slot test is flaky and fix it without adding sleeps.", source: "initial", task: taskID),
            ActivityFixture.text(1, "I'll start with the slot release path and the test.", task: taskID),
            toolRow(2, "c-read-1", category: "read", name: "Read", path: "/repo/slots.py", output: ""),
            toolRow(3, "c-read-2", category: "read", name: "Read", path: "/repo/test_slots.py", output: ""),
            ActivityFixture.text(4, list, task: taskID),
            toolRow(5, "c-edit-a", category: "edit", name: "Edit", path: "/repo/slots.py", old: "release()\nnotify()",
                    new: "with lock:\n    release()\n    notify()", output: "ok\nsaved\nformatted"),
            toolRow(6, "c-write", category: "write", name: "Write", path: "/repo/notes.txt", output: "Wrote 12 lines\nFormatted with ruff"),
            toolRow(7, "c-run", category: "shell", name: "Bash", command: "pytest -k release", output: longOutput),
            ActivityFixture.separator("Also check the retry path.", task: taskID),
            ActivityFixture.text(9, "The retry path already re-checks the count.", task: taskID)
        ]
        if live {
            rows.append(toolRow(10, "c-live", category: "shell", name: "Bash", command: "pytest tests", output: nil, running: true))
        }
        return rows
    }

}

// MARK: - Probe support

@MainActor private final class WidthBox { var value: CGFloat = 0 }
