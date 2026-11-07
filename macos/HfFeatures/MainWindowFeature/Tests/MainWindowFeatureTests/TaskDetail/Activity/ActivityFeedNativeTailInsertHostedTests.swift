import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import ObjectiveC
import SwiftUI
import Testing

// MARK: - TableReloadSpy

/// Counts `NSTableView.reloadData` per table instance without touching product source. The
/// pass-through swizzle is installed once per process; counts are keyed by table identity, so
/// concurrent suites that own other tables do not disturb a measurement.
private enum TableReloadSpy {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var counts: [ObjectIdentifier: Int] = [:]

    static let install: Void = {
        let selector = Selector(("reloadData"))
        guard let method = class_getInstanceMethod(NSTableView.self, selector) else { return }
        typealias Original = @convention(c) (AnyObject, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let block: @convention(block) (AnyObject) -> Void = { table in
            record(table)
            original(table, selector)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }()

    private static func record(_ table: AnyObject) {
        lock.lock()
        counts[ObjectIdentifier(table), default: 0] += 1
        lock.unlock()
    }

    static func count(_ table: AnyObject) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[ObjectIdentifier(table)] ?? 0
    }
}

// MARK: - ActivityFeedNativeTailInsertHostedTests

/// Hosted behaviour of the live-append transaction: reload routing, row and entry mapping at
/// every index, immediate frames, the reading kept across a window slide, and hosted roots that
/// stay current when a row changes while rows leave.
@MainActor @Suite(.serialized) struct ActivityFeedNativeTailInsertHostedTests {
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

        /// A row's distance below the viewport top, from the live table rects.
        func relativeOffset(of id: String) -> CGFloat? {
            index(of: id).map { table.rect(ofRow: $0).minY - scroll.documentVisibleRect.minY }
        }
    }

    // MARK: Following

    @Test func givenFollowingFeed_whenRowAppended_thenTableIsNotReloaded() async throws {
        // given
        let mounted = try await mount(1 ... 40)
        defer { mounted.close() }
        try #require(mounted.state.followLive.isFollowing)
        let reloads = TableReloadSpy.count(mounted.table)
        // when
        mounted.update(feed(1 ... 41, state: mounted.state))
        await waitUntil(timeout: 5) { mounted.index(of: "ti-41") != nil }
        // then
        try #require(mounted.index(of: "ti-41") != nil)
        #expect(TableReloadSpy.count(mounted.table) == reloads, "live append must not call reloadData")
        #expect(mounted.table.numberOfRows == mounted.owner.entries.count)
        #expect(abs(mounted.table.bounds.maxY - mounted.scroll.documentVisibleRect.maxY) < 3)
    }

    @Test func givenFollowingFeed_whenRowAppended_thenSentinelKeepsSixteenPointsAndBottomStaysPinned() async throws {
        // given
        let mounted = try await mount(1 ... 40)
        defer { mounted.close() }
        // when
        mounted.update(feed(1 ... 41, state: mounted.state))
        await waitUntil(timeout: 5) { mounted.index(of: "ti-41") != nil }
        // then — issue 44: the closing sentinel is 16 pt and the last pixel of it is in view.
        let sentinel = try #require(mounted.index(of: "activity-feed-bottom"))
        #expect(sentinel == mounted.owner.entries.count - 1)
        #expect(abs(mounted.table.rect(ofRow: sentinel).height - 16) < 2)
        #expect(abs(mounted.scroll.documentVisibleRect.maxY - mounted.table.rect(ofRow: sentinel).maxY) < 3)
        #expect(mounted.state.followLive.isFollowing)
    }

    @Test func givenFollowingFeed_whenModelAppliedSynchronously_thenFramesAreFinalInTheSameTurn() async throws {
        // given — the coordinator is driven directly, so nothing can run between update and check.
        let mounted = try await mount(1 ... 40)
        defer { mounted.close() }
        var model = try #require(mounted.owner.model)
        mounted.owner.update(model: model, state: mounted.state, environment: EnvironmentValues(), actions: mounted.owner.actions)
        let reloads = TableReloadSpy.count(mounted.table)
        // when
        model.shownRows = rows(1 ... 42)
        model.allRowIDs = (1 ... 42).map { "ti-\($0)" }
        mounted.owner.update(model: model, state: mounted.state, environment: EnvironmentValues(), actions: mounted.owner.actions)
        // then — no await since the update: no animation can have run.
        try #require(mounted.index(of: "ti-42") != nil)
        #expect(TableReloadSpy.count(mounted.table) == reloads)
        assertContiguousRects(mounted)
        for (row, cell) in try realizedCells(mounted) {
            let slot = mounted.table.rect(ofRow: row)
            let frame = cell.convert(cell.bounds, to: mounted.table)
            #expect(abs(frame.minY - slot.minY) < 1.5, "row \(row) cell is mid-animation")
            #expect(abs(frame.height - slot.height) < 1.5)
        }
        #expect(abs(mounted.table.bounds.maxY - mounted.scroll.documentVisibleRect.maxY) < 3)
    }

    // MARK: Window slide

    @Test func givenFullWindow_whenThreeRowsAppended_thenRowCountAndEveryIndexMatchTheSlidWindow() async throws {
        // given — 100 rows shown, history not exhausted (no header).
        let mounted = try await mount(1 ... 100)
        defer { mounted.close() }
        let reloads = TableReloadSpy.count(mounted.table)
        // when — 103 rows exist, so the window now shows rows 4 ... 103.
        mounted.update(feed(1 ... 103, state: mounted.state))
        await waitUntil(timeout: 8) { mounted.index(of: "ti-103") != nil }
        // then
        let expected = (4 ... 103).map { "ti-\($0)" } + ["activity-feed-bottom"]
        #expect(mounted.owner.entries.map(\.id) == expected)
        #expect(mounted.owner.boxes.map(\.entry.id) == expected)
        #expect(mounted.table.numberOfRows == expected.count)
        #expect(TableReloadSpy.count(mounted.table) == reloads, "a window slide must not call reloadData")
        for (row, cell) in try realizedCells(mounted) {
            try #require(expected.indices.contains(row))
            #expect(cell.entryID == expected[row], "row \(row) hosts the wrong entry")
            #expect(mounted.table.row(for: cell) == row)
        }
        assertContiguousRects(mounted)
        #expect(abs(mounted.table.bounds.maxY - mounted.scroll.documentVisibleRect.maxY) < 3)
    }

    @Test func givenExactlyFullWindowWithBeginningHeader_whenFirstSlideHappens_thenHeaderIsGoneAndFirstRowIsMeasuredAtTwelve() async throws {
        // given — 100 rows with the exhausted-history header.
        let mounted = try await mount(1 ... 100, hasMore: false)
        defer { mounted.close() }
        try #require(mounted.owner.entries.first == .header(.beginning))
        // when
        mounted.update(feed(1 ... 101, state: mounted.state, hasMore: false))
        await waitUntil(timeout: 8) { mounted.index(of: "ti-101") != nil }
        // then
        let expected = (2 ... 101).map { "ti-\($0)" } + ["activity-feed-bottom"]
        #expect(mounted.owner.entries.map(\.id) == expected)
        #expect(mounted.table.numberOfRows == expected.count)
        guard case .row(let first) = mounted.owner.entries[0] else {
            Issue.record("first entry is not a row")
            return
        }
        #expect(first.topSpacing == 12)
        let fresh = try #require(mounted.owner.measure(mounted.owner.boxes[0], width: mounted.owner.currentWidth))
        #expect(abs(mounted.table.rect(ofRow: 0).height - fresh) < 2, "first row slot must match its 12 pt natural height")
        assertContiguousRects(mounted)
    }

    @Test func givenWindowSlideWithoutHeader_whenSurvivingRowBecomesFirst_thenItsSlotShrinksByEightPoints() async throws {
        // given
        let mounted = try await mount(1 ... 100)
        defer { mounted.close() }
        let before = try #require(mounted.index(of: "ti-2"))
        let interiorHeight = mounted.table.rect(ofRow: before).height
        // when — row 2 becomes the first row.
        mounted.update(feed(1 ... 101, state: mounted.state))
        await waitUntil(timeout: 8) { mounted.index(of: "ti-101") != nil }
        // then — 20 pt of top spacing becomes 12.
        try #require(mounted.index(of: "ti-2") == 0)
        #expect(abs((interiorHeight - mounted.table.rect(ofRow: 0).height) - 8) < 1.5)
        let fresh = try #require(mounted.owner.measure(mounted.owner.boxes[0], width: mounted.owner.currentWidth))
        #expect(abs(mounted.table.rect(ofRow: 0).height - fresh) < 2)
    }

    @Test func givenPinnedBoundaryBeyondPageSize_whenRowAppended_thenNothingSlides() async throws {
        // given — pinning the boundary keeps all rows of a 110 row feed.
        let state = ParallelColumnUIState()
        state.retainedFirstID = "ti-1"
        let mounted = try await mount(1 ... 110, state: state)
        defer { mounted.close() }
        try #require(mounted.index(of: "ti-1") == 0)
        // when
        mounted.update(feed(1 ... 111, state: mounted.state))
        await waitUntil(timeout: 8) { mounted.index(of: "ti-111") != nil }
        // then
        #expect(mounted.index(of: "ti-1") == 0)
        #expect(mounted.owner.entries.count == 112)
        #expect(mounted.table.numberOfRows == 112)
    }

    // MARK: Paused reading

    @Test func givenPausedReader_whenRowAppendedOnly_thenOffsetIsNotWritten() async throws {
        // given
        let mounted = try await mount(1 ... 40)
        defer { mounted.close() }
        try await pause(mounted, atRow: "ti-20", inset: 30)
        let offset = mounted.scroll.documentVisibleRect.minY
        let reloads = TableReloadSpy.count(mounted.table)
        // when
        mounted.update(feed(1 ... 41, state: mounted.state))
        await waitUntil(timeout: 5) { mounted.index(of: "ti-41") != nil }
        // then
        #expect(TableReloadSpy.count(mounted.table) == reloads, "a paused append must not call reloadData")
        #expect(abs(mounted.scroll.documentVisibleRect.minY - offset) < 0.5)
        #expect(!mounted.state.followLive.isFollowing)
    }

    @Test func givenPausedReader_whenSameIDRowsAboveViewportGrowWithAppend_thenAnchorRowKeepsItsPlace() async throws {
        // given
        let mounted = try await mount(1 ... 40)
        defer { mounted.close() }
        try await pause(mounted, atRow: "ti-20", inset: 30)
        let anchor = try #require(mounted.state.anchor?.id)
        let before = try #require(mounted.relativeOffset(of: anchor))
        let growing = try #require(mounted.index(of: "ti-3"))
        let height = mounted.table.rect(ofRow: growing).height
        // when — rows 3 and 5 grow above the viewport in the same update that appends a row.
        mounted.update(feed(1 ... 41, state: mounted.state, grown: [3, 5]))
        await waitUntil(timeout: 5) {
            mounted.index(of: "ti-41") != nil && mounted.table.rect(ofRow: growing).height > height + 20
        }
        // then
        try #require(mounted.table.rect(ofRow: growing).height > height + 20)
        let after = try #require(mounted.relativeOffset(of: anchor))
        #expect(abs(after - before) < 3)
        #expect(!mounted.state.followLive.isFollowing)
    }

    @Test func givenPausedReader_whenEnvironmentRemeasuresWithAppend_thenAnchorRowKeepsItsPlace() async throws {
        // given
        let mounted = try await mount(1 ... 40)
        defer { mounted.close() }
        try await pause(mounted, atRow: "ti-20", inset: 30)
        let anchor = try #require(mounted.state.anchor?.id)
        let before = try #require(mounted.relativeOffset(of: anchor))
        let height = mounted.table.rect(ofRow: try #require(mounted.index(of: "ti-3"))).height
        let reloads = TableReloadSpy.count(mounted.table)
        // when — wider padding rewraps every row (the root-input invalidation path) and a row arrives.
        mounted.update(feed(1 ... 41, state: mounted.state, padding: 72, dynamicType: .xxxLarge))
        await waitUntil(timeout: 5) {
            mounted.index(of: "ti-41") != nil
                && mounted.table.rect(ofRow: mounted.index(of: "ti-3") ?? 0).height > height + 5
        }
        // then
        try #require(mounted.table.rect(ofRow: try #require(mounted.index(of: "ti-3"))).height > height + 5)
        let after = try #require(mounted.relativeOffset(of: anchor))
        #expect(abs(after - before) < 3)
        #expect(!mounted.state.followLive.isFollowing)
        #expect(mounted.table.numberOfRows == mounted.owner.entries.count)
        #expect(TableReloadSpy.count(mounted.table) > reloads, "a remeasuring update takes the structural route")
    }

    @Test func givenPausedReaderOnFirstRows_whenSlideRemovesTheCapturedRow_thenOffsetClampsToTopWithSurvivorFirstAndStillPaused() async throws {
        // given — reading at the very top: rows 1 and 2 are visible and will leave the window.
        let mounted = try await mount(1 ... 100)
        defer { mounted.close() }
        try await pause(mounted, atRow: "ti-1", inset: 10)
        try #require(mounted.owner.captureReading()?.id == "ti-1")
        let survivor = "ti-3"
        try #require(mounted.index(of: "ti-1") == 0 && mounted.index(of: "ti-2") == 1)
        try #require(mounted.relativeOffset(of: survivor).map { $0 > 0 && $0 < mounted.scroll.documentVisibleRect.height } == true)
        // when — rows 1 and 2 leave the window. The view pins a paused reader's boundary, so the
        // model is driven straight into the coordinator, as a transient unpinned window would.
        var model = try #require(mounted.owner.model)
        mounted.owner.update(model: model, state: mounted.state, environment: EnvironmentValues(), actions: mounted.owner.actions)
        await Task.yield()
        model.shownRows = rows(3 ... 102)
        model.allRowIDs = (1 ... 102).map { "ti-\($0)" }
        mounted.owner.update(model: model, state: mounted.state, environment: EnvironmentValues(), actions: mounted.owner.actions)
        await waitUntil(timeout: 8) { mounted.index(of: "ti-102") != nil }
        // then — everything above the survivor left with it, so the reader clamps to the top:
        // offset 0, the first surviving row at the origin and visible, and still not following.
        try #require(mounted.index(of: "ti-1") == nil)
        try #require(mounted.index(of: survivor) == 0)
        #expect(abs(mounted.scroll.documentVisibleRect.minY) < 1.5, "offset \(mounted.scroll.documentVisibleRect.minY)")
        let after = try #require(mounted.relativeOffset(of: survivor))
        #expect(abs(after) < 1.5, "survivor relative offset \(after)")
        #expect(mounted.table.rect(ofRow: 0).intersects(mounted.scroll.documentVisibleRect))
        #expect(!mounted.state.followLive.isFollowing)
    }

    // MARK: Hosted roots stay current

    @Test func givenPausedReader_whenTallLeadingRowsLeaveAndSurvivorBecomesFirst_thenRealizedRootsAreCurrent() async throws {
        // given — rows 1 and 2 together are taller than the viewport; row 3 is visible below them.
        let mounted = try await mount(1 ... 100, tall: [1, 2])
        defer { mounted.close() }
        let second = try #require(mounted.index(of: "ti-2"))
        let secondRect = mounted.table.rect(ofRow: second)
        try #require(secondRect.height > 100)
        try await pause(mounted, atRow: "ti-2", inset: secondRect.height - 60)
        let survivor = try #require(mounted.owner.cells["ti-3"], "row 3 must be realized before the slide")
        try #require(survivor.host?.rootView.entry.topSpacing == 20)
        let removedHeight = mounted.table.rect(ofRow: try #require(mounted.index(of: "ti-3"))).minY
        try #require(removedHeight > mounted.scroll.contentView.bounds.height)
        // when — the view pins a paused boundary, so the model goes straight into the coordinator.
        var model = try #require(mounted.owner.model)
        mounted.owner.update(model: model, state: mounted.state, environment: EnvironmentValues(), actions: mounted.owner.actions)
        await Task.yield()
        model.shownRows = rows(3 ... 102)
        model.allRowIDs = (1 ... 102).map { "ti-\($0)" }
        mounted.owner.update(model: model, state: mounted.state, environment: EnvironmentValues(), actions: mounted.owner.actions)
        await waitUntil(timeout: 8) { mounted.index(of: "ti-102") != nil }
        // then — row 3 is now first with 12 points of spacing, in its hosted root as well as its slot.
        try #require(mounted.index(of: "ti-3") == 0)
        #expect(abs(mounted.scroll.documentVisibleRect.minY) < 1.5)
        #expect(!mounted.state.followLive.isFollowing)
        try assertRealizedRootsAreCurrent(mounted)
        let first = try #require(mounted.owner.cells["ti-3"])
        #expect(first.host?.rootView.entry.topSpacing == 12, "hosted root kept topSpacing \(String(describing: first.host?.rootView.entry.topSpacing))")
    }

    @Test func givenFollowingFeed_whenTallLeadingRowsLeaveAndVisibleRowChanges_thenRealizedRootsAreCurrent() async throws {
        // given — rows 1 and 2 together are taller than the viewport; the last rows are in view.
        let mounted = try await mount(1 ... 100, tall: [1, 2])
        defer { mounted.close() }
        try #require(mounted.state.followLive.isFollowing)
        let removedHeight = mounted.table.rect(ofRow: try #require(mounted.index(of: "ti-3"))).minY
        try #require(removedHeight > mounted.scroll.contentView.bounds.height)
        let changing = try #require(mounted.owner.cells["ti-100"], "row 100 must be realized before the update")
        let oldEntry = try #require(changing.host?.rootView.entry)
        // when — the window slides by two while a visible retained row changes.
        mounted.update(feed(1 ... 102, state: mounted.state, grown: [100]))
        await waitUntil(timeout: 8) { mounted.index(of: "ti-102") != nil }
        // then
        let index = try #require(mounted.index(of: "ti-100"))
        try #require(mounted.owner.entries[index] != oldEntry)
        try #require(mounted.table.rect(ofRow: index).intersects(mounted.scroll.documentVisibleRect))
        try assertRealizedRootsAreCurrent(mounted)
        let hosted = try #require(mounted.owner.cells["ti-100"]?.host?.rootView.entry)
        #expect(hosted == mounted.owner.entries[index], "hosted root for row 100 is stale")
        #expect(mounted.state.followLive.isFollowing)
    }

    // MARK: Real route

    @Test func givenApprovalRevealSuspendedReader_whenWindowSlidesThroughTheView_thenReadingRowKeepsItsPlace() async throws {
        // given — the reveal suspends follow without pinning a boundary, so the real view slides.
        let card = approvalCard("reveal-1")
        let mounted = try await mount(1 ... 100, approvals: [card], hasLoader: true)
        defer { mounted.close() }
        let reveal = CallerApprovalReveal(requestID: card.id, token: UUID())
        mounted.update(feed(1 ... 100, state: mounted.state, approvals: [card], reveal: reveal, hasLoader: true))
        await waitUntil(timeout: 8) {
            !mounted.state.followLive.isFollowing && mounted.owner.consumedApprovalReveal == reveal.token
        }
        try #require(!mounted.state.followLive.isFollowing)
        try #require(mounted.state.retainedFirstID == nil, "the reveal route pinned the boundary")
        let reading = try #require(mounted.owner.captureReading()?.id)
        let before = try #require(mounted.relativeOffset(of: reading))
        let reloads = TableReloadSpy.count(mounted.table)
        // when
        mounted.update(feed(1 ... 102, state: mounted.state, approvals: [card], reveal: reveal, hasLoader: true))
        await waitUntil(timeout: 8) { mounted.index(of: "ti-102") != nil }
        // then
        try #require(mounted.index(of: "ti-1") == nil)
        let after = try #require(mounted.relativeOffset(of: reading))
        #expect(abs(after - before) < 3, "reading row \(reading) moved by \(after - before)")
        #expect(!mounted.state.followLive.isFollowing)
        #expect(TableReloadSpy.count(mounted.table) == reloads)
        try assertRealizedRootsAreCurrent(mounted)
    }

    // MARK: Fallback

    @Test func givenWindowedTableThatIsNotPositioned_whenRowAppended_thenRowCountAndIDsAreCorrect() async throws {
        // given — a zero-height viewport never positions the table.
        let mounted = try await mount(1 ... 50, height: 0, awaitPositioned: false)
        defer { mounted.close() }
        await waitUntil(timeout: 5) { mounted.owner.entries.count == 51 }
        try #require(mounted.owner.entries.count == 51)
        try #require(!mounted.owner.positioned)
        try #require(mounted.table.window != nil)
        let reloads = TableReloadSpy.count(mounted.table)
        // when
        mounted.update(feed(1 ... 51, state: mounted.state, height: 0))
        await waitUntil(timeout: 5) { mounted.index(of: "ti-51") != nil }
        // then
        try #require(!mounted.owner.positioned)
        #expect(TableReloadSpy.count(mounted.table) > reloads, "an unpositioned table falls back to reloadData")
        #expect(mounted.table.numberOfRows == 52)
        #expect(mounted.owner.boxes.map(\.entry.id) == mounted.owner.entries.map(\.id))
        #expect(mounted.owner.entries.last?.id == "activity-feed-bottom")
        #expect(mounted.owner.entries[50].id == "ti-51")
    }

    // MARK: Helpers

    private func mount(_ range: ClosedRange<Int>, hasMore: Bool = true, height: CGFloat = 450,
                       state: ParallelColumnUIState = ParallelColumnUIState(),
                       tall: Set<Int> = [], approvals: [CallerApprovalCardModel] = [], hasLoader: Bool = false,
                       awaitPositioned: Bool = true) async throws -> Mounted {
        _ = TableReloadSpy.install
        _ = NSApplication.shared
        let host = NSHostingView(rootView: AnyView(feed(range, state: state, hasMore: hasMore, tall: tall,
                                                        approvals: approvals, hasLoader: hasLoader, height: height)))
        let window = activityMountedTestWindow(host, style: [.titled, .resizable])
        window.orderFront(nil)
        if awaitPositioned {
            await waitUntil(timeout: 8) { state.viewportPositioned }
        } else { await waitUntil(timeout: 5) { !activityNativeDescendants(host).compactMap { $0 as? ActivityFeedNativeTableView }.isEmpty } }
        let table = try #require(activityNativeDescendants(host).compactMap { $0 as? ActivityFeedNativeTableView }.first)
        let scroll = try #require(table.enclosingScrollView)
        let owner = try #require(table.owner)
        if awaitPositioned {
            // Positive control: initial positioning always reloads, so a failed swizzle reads zero.
            try #require(TableReloadSpy.count(table) > 0, "the reloadData spy is not counting")
        }
        return Mounted(state: state, host: host, window: window, table: table, scroll: scroll, owner: owner)
    }

    private func pause(_ mounted: Mounted, atRow id: String, inset: CGFloat) async throws {
        let index = try #require(mounted.index(of: id))
        activityNativeTestScroll(mounted.scroll, to: mounted.table.rect(ofRow: index).minY + inset)
        await waitUntil(timeout: 3) { !mounted.state.followLive.isFollowing && mounted.state.anchor != nil }
        try #require(!mounted.state.followLive.isFollowing)
        // Let the pause's own first-appearance refresh settle before recording baselines.
        await waitUntil(timeout: 3) {
            mounted.owner.entries.allSatisfy { entry in
                if case .row(let row) = entry { return !row.fade }
                return true
            }
        }
    }

    /// The cells AppKit itself reports for the rows in the visible rect, with their row numbers.
    private func realizedCells(_ mounted: Mounted) throws -> [(row: Int, cell: ActivityFeedNativeCell)] {
        let range = mounted.table.rows(in: mounted.table.visibleRect)
        var result: [(row: Int, cell: ActivityFeedNativeCell)] = []
        for row in range.location ..< range.location + range.length {
            if let cell = mounted.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ActivityFeedNativeCell {
                result.append((row, cell))
            }
        }
        try #require(!result.isEmpty, "no realized cells in the visible rect")
        return result
    }

    /// Every realized cell hosts exactly the entry (spacing included) its row currently owns.
    private func assertRealizedRootsAreCurrent(_ mounted: Mounted) throws {
        for (row, cell) in try realizedCells(mounted) {
            let entry = mounted.owner.entries[row]
            #expect(cell.entryID == entry.id, "row \(row) hosts \(String(describing: cell.entryID))")
            #expect(cell.host?.rootView.entry == entry, "row \(row) (\(entry.id)) hosts a stale root")
            #expect(cell.host?.rootView.entry.topSpacing == entry.topSpacing,
                    "row \(row) (\(entry.id)) hosts topSpacing \(String(describing: cell.host?.rootView.entry.topSpacing))")
        }
    }

    private func approvalCard(_ id: String) -> CallerApprovalCardModel {
        let request = CallerApprovalRequest(raw: [
            "request_id": .string(id), "task_id": .string("tail-insert-task"), "tool_name": .string("Bash"),
            "cwd": .string("/workspace/repo"), "freedom": .string("write_in_repo"),
            "scope": .string("exact_action_once"), "disposition": .string("pending"),
            "delivery": .string("pending"), "execution_outcome": .string("unknown"),
            "action": .object(["tool_name": .string("Bash"),
                               "input": .object(["command": .string("swift test")])])
        ])
        return CallerApprovalCardModel(request: request, action: CallerApprovalAction.build(request),
                                       pending: true, expanded: true, canRespond: true,
                                       notice: nil, submitting: false)
    }

    private func assertContiguousRects(_ mounted: Mounted) {
        var previousMaxY: CGFloat = 0
        for row in 0 ..< mounted.table.numberOfRows {
            let rect = mounted.table.rect(ofRow: row)
            if abs(rect.minY - previousMaxY) >= 0.5 { Issue.record("row \(row) starts at \(rect.minY), expected \(previousMaxY)") }
            previousMaxY = rect.maxY
        }
        #expect(abs(mounted.table.bounds.height - previousMaxY) < 1.5)
    }

    private func rows(_ range: ClosedRange<Int>, grown: Set<Int> = [], tall: Set<Int> = []) -> [ActivityRow] {
        range.map { index in
            let repeats = tall.contains(index) ? 24 : grown.contains(index) ? 14 : 4
            return ActivityRow.single(ConversationTimelineRow(
                id: "ti-\(index)", taskID: "tail-insert-task", timestamp: nil,
                kind: .item(PreviewFixtures.textItem(
                    String(repeating: "Row \(index) wraps across the native reading width. ", count: repeats), seq: index)),
                live: false))
        }
    }

    private func feed(_ range: ClosedRange<Int>, state: ParallelColumnUIState, hasMore: Bool = true,
                      grown: Set<Int> = [], tall: Set<Int> = [], padding: CGFloat = 12,
                      dynamicType: DynamicTypeSize? = nil, approvals: [CallerApprovalCardModel] = [],
                      reveal: CallerApprovalReveal? = nil, hasLoader: Bool = false,
                      height: CGFloat = 450) -> some View {
        let rows = rows(range, grown: grown, tall: tall)
        let presentation: ActivityFeedTailPresentation = approvals.isEmpty ? .absent : .standard(.init(approvals: approvals))
        return ActivityFeedView(rows: rows, start: nil, history: EventHistoryState(hasMore: hasMore), isLoading: false,
                                horizontalPadding: padding, state: state,
                                onLoadMore: hasLoader ? { false } : nil,
                                tailPresentation: presentation, approvalReveal: reveal)
            .environment(\.hfReduceMotionOverride, true)
            .environment(\.dynamicTypeSize, dynamicType ?? .large)
            .frame(width: 420, height: height)
    }
}
