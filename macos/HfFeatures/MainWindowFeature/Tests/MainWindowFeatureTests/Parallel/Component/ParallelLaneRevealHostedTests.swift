import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - ParallelLaneRevealHostedTests

/// Keyboard reach of Parallel lanes at a minimum window: two whole 360-point lanes and a peek. Focus
/// ENTERING a lane scrolls the row the minimum distance that shows that whole lane, and the lane that
/// then comes into view becomes resident. Live Tab delivery cannot be sent by the harness, so the tests
/// make the lane's field the first responder (what Tab does) and record Tab itself as unverified.
@MainActor @Suite(.serialized) struct ParallelLaneRevealHostedTests {
    private static let detailWidth: CGFloat = 736

    @MainActor private struct Mounted {
        let fixture: RedesignHost
        let harness: ParallelVMTests.SUT
        var window: NSWindow { fixture.window }

        /// The row's horizontal scroll view: the one whose document is five lane strides wide.
        var horizontalScroll: NSScrollView? {
            fixture.descendants
.compactMap { $0 as? NSScrollView }
                .first { scroll in scroll.documentView.map { abs($0.frame.width - 5 * ParallelTestGeometry.laneStride) < 3 } == true }
        }

        /// The lane message fields, left to right.
        var fields: [NSTextField] {
            fixture.descendants
.compactMap { $0 as? NSTextField }
                .filter { $0.placeholderString == "Queue a message…" }
                .sorted { fixture.host.convert($0.bounds, from: $0).minX < fixture.host.convert($1.bounds, from: $1).minX }
        }
    }

    private func mount() async throws -> Mounted {
        let tests = ParallelVMTests()
        let harness = tests.makeSUT()
        let tasks = (0 ..< 5).map { tests.task(id: "task-\($0)", startedAt: Date(timeIntervalSince1970: Double($0))) }
        harness.tasksBox.value = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskID, $0) })
        let fixture = RedesignHost(ParallelView(harness.sut, initiallyPrepared: true),
                                   size: CGSize(width: Self.detailWidth, height: 620))
        harness.tasksSubject.send(tasks)
        let mounted = Mounted(fixture: fixture, harness: harness)
        await fixture.settle {
            harness.sut.columns.count == 5 && harness.sut.residentColumnCount == 3 && harness.sut.isPresentationSettled
                && mounted.fields.count == 3 && mounted.horizontalScroll != nil
        }
        try #require(harness.sut.residentColumnCount == 3, "two whole lanes and a 14 pt peek are resident")
        try #require(mounted.fields.count == 3)
        return mounted
    }

    /// Lets the run loop deliver pending focus, layout and scroll notifications (a synchronous helper, since
    /// `RunLoop.run(until:)` cannot be called directly from an async context).
    private func pump(turns: Int = 20) {
        for _ in 0 ..< turns { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
    }

    /// Moves focus the way a keyboard (Tab, Shift-Tab) or a pointer would: the harness cannot deliver a real key
    /// event, so it replaces the observer's event-type probe for the duration of the focus change (recorded as
    /// unverified against a real Tab).
    @discardableResult
    private func focus(_ field: NSTextField, keyboard: Bool = true) -> Bool {
        ParallelScrollObservationView.focusEventType = { keyboard ? .keyDown : .leftMouseDown }
        defer { ParallelScrollObservationView.focusEventType = { NSApp.currentEvent?.type } }
        return field.window?.makeFirstResponder(field) ?? false
    }

    private func close(_ mounted: Mounted) {
        mounted.harness.sut.didDisappear()
        mounted.fixture.close()
    }

    @Test func givenMinimumWindow_whenLaneGeometryIsMeasured_thenTwoWholeLanesAndAPeekShow() async throws {
        // given / when
        let mounted = try await mount()
        defer { close(mounted) }
        let scroll = try #require(mounted.horizontalScroll)

        // then — lanes are 360 wide with a 1 pt separator: 2 * 361 = 722 of the 736, leaving a 14 pt peek.
        let stride = ParallelTestGeometry.laneStride
        #expect(stride == 361)
        #expect(scroll.contentView.bounds.width == Self.detailWidth)
        let third = mounted.fixture.host.convert(mounted.fields[2].bounds, from: mounted.fields[2])
        #expect(third.minX >= 2 * stride, "the peek lane's field lies beyond the viewport, reachable only by scrolling")
        #expect(Self.detailWidth - 2 * stride == 14)
    }

    @Test func givenThePeekLane_whenItsFieldTakesFocus_thenTheRowScrollsItWhollyIntoViewAndTheNextLaneBecomesResident() async throws {
        // given
        let mounted = try await mount()
        defer { close(mounted) }
        let scroll = try #require(mounted.horizontalScroll)
        let stride = ParallelTestGeometry.laneStride
        #expect(scroll.documentVisibleRect.minX == 0)

        // when — what Tab does: the peek lane's field becomes first responder.
        mounted.window.makeKeyAndOrderFront(nil)
        let field = mounted.fields[2]
        #expect(focus(field))
        let laneMax = 3 * stride - ParallelLayout.dividerWidth
        await mounted.fixture.settle { scroll.documentVisibleRect.maxX >= laneMax - 0.5 }

        // then — minimum distance plus the separator and 1 pt of the next lane (so that lane is geometry-resident).
        let visible = scroll.documentVisibleRect
        #expect(abs(visible.maxX - (laneMax + ParallelLayout.dividerWidth + 1)) < 1, "the lane is scrolled just fully into view: \(visible)")
        let laneFrame = CGRect(x: 2 * stride, y: 0, width: ParallelLayout.minimumColumnWidth, height: 1)
        #expect(visible.contains(laneFrame.origin) && visible.maxX >= laneFrame.maxX)

        // then — the fourth lane now intersects the viewport, so it is resident and leased.
        await mounted.fixture.settle { mounted.harness.sut.residentColumnCount == 4 && mounted.harness.sut.isPresentationSettled }
        #expect(mounted.harness.sut.residentColumnCount == 4)
        #expect(mounted.harness.sut.leasedMemberCount == 4)
    }

    @Test func givenFocusStaysInALane_whenTheUserScrollsAwayAndTheViewRerenders_thenThePositionHolds() async throws {
        // given — focus is inside the peek lane and the row has revealed it.
        let mounted = try await mount()
        defer { close(mounted) }
        let scroll = try #require(mounted.horizontalScroll)
        mounted.window.makeKeyAndOrderFront(nil)
        #expect(focus(mounted.fields[2]))
        let laneMax = 3 * ParallelTestGeometry.laneStride - ParallelLayout.dividerWidth
        await mounted.fixture.settle { scroll.documentVisibleRect.maxX >= laneMax - 0.5 }

        // when — a manual scroll back to the start, then unrelated model churn.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        mounted.harness.busySubject.send(["task-0"])
        mounted.harness.busySubject.send([])
        pump()
        mounted.fixture.host.layoutSubtreeIfNeeded()
        pump()

        // then — focus did not change lanes, so nothing pulls the row back.
        #expect(scroll.documentVisibleRect.minX < 1, "manual position holds: \(scroll.documentVisibleRect)")
    }

    @Test func givenALaneAlreadyWhollyVisible_whenItsFieldTakesFocus_thenTheRowDoesNotMove() async throws {
        // given
        let mounted = try await mount()
        defer { close(mounted) }
        let scroll = try #require(mounted.horizontalScroll)

        // when
        mounted.window.makeKeyAndOrderFront(nil)
        #expect(focus(mounted.fields[1]))
        pump()

        // then
        #expect(scroll.documentVisibleRect.minX == 0)
    }

    @Test func givenTheRowAtTheEnd_whenTheLeftmostResidentFieldTakesKeyboardFocus_thenItsLaneIsWholeAndThePreviousLaneBecomesResident() async throws {
        // given — scrolled to the end: lanes 2 (a 13 pt sliver), 3 and 4 are resident.
        let mounted = try await mount()
        defer { close(mounted) }
        let scroll = try #require(mounted.horizontalScroll)
        let stride = ParallelTestGeometry.laneStride
        let end = 5 * stride - Self.detailWidth
        scroll.contentView.scroll(to: CGPoint(x: end, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        await mounted.fixture.settle { mounted.harness.sut.leasedMemberCount == 3 && mounted.harness.sut.isPresentationSettled && mounted.fields.count == 3 }
        try #require(mounted.fields.count == 3)

        // when — Shift-Tab into the leftmost resident lane.
        mounted.window.makeKeyAndOrderFront(nil)
        #expect(focus(mounted.fields[0]))
        await mounted.fixture.settle { scroll.documentVisibleRect.minX < 2 * stride }

        // then — lane 2 is whole plus its separator and the last point of lane 1.
        let visible = scroll.documentVisibleRect
        #expect(abs(visible.minX - (2 * stride - ParallelLayout.dividerWidth - 1)) < 1, "visible \(visible)")
        #expect(visible.minX <= 2 * stride && visible.maxX >= 3 * stride - ParallelLayout.dividerWidth)
        // then — lane 1 intersects the viewport, so it is leased and its controls exist for the next Shift-Tab.
        await mounted.fixture.settle { mounted.harness.sut.leasedMemberCount == 4 && mounted.harness.sut.isPresentationSettled }
        #expect(mounted.harness.sut.leasedMemberCount == 4)
    }

    @Test func givenAPartlyHiddenLane_whenItsFieldTakesPointerFocus_thenTheRowDoesNotMoveButKeyboardFocusMovesIt() async throws {
        // given
        let mounted = try await mount()
        defer { close(mounted) }
        let scroll = try #require(mounted.horizontalScroll)
        mounted.window.makeKeyAndOrderFront(nil)

        // when — a click into the peek lane's field (a mouse-initiated focus change)
        #expect(focus(mounted.fields[2], keyboard: false))
        pump()
        // then — the row stays under the pointer.
        #expect(scroll.documentVisibleRect.minX == 0, "pointer focus scrolled the row: \(scroll.documentVisibleRect)")

        // when — the keyboard moves focus out, then into the same lane
        #expect(focus(mounted.fields[0]))
        #expect(focus(mounted.fields[2]))
        let laneMax = 3 * ParallelTestGeometry.laneStride - ParallelLayout.dividerWidth
        await mounted.fixture.settle { scroll.documentVisibleRect.maxX >= laneMax - 0.5 }

        // then — only now does the row reveal it.
        #expect(scroll.documentVisibleRect.maxX >= laneMax)
    }

    @Test func givenAPendingRestoration_whenKeyboardFocusEntersALane_thenTheRevealWinsAndRestorationDoesNotSnapBack() async throws {
        // given — an observer whose id list changed once, so it holds a preserved horizontal offset of 0.
        let row = try await RevealRow.mounted(laneCount: 5, documentLanes: 5)
        defer { row.close() }
        row.observer.configure(ids: row.ids + ["f"], stride: ParallelTestGeometry.laneStride, restorationOffset: nil, restorationActive: false)
        row.setDocumentLanes(6)
        pump()
        #expect(row.scroll.documentVisibleRect.minX == 0)

        // when — keyboard focus enters lane 2 (a 14 pt peek)
        row.focus(lane: 2, keyboard: true)
        let target = 3 * ParallelTestGeometry.laneStride - ParallelLayout.dividerWidth + 2 - row.viewportWidth
        await row.settle { abs(row.scroll.documentVisibleRect.minX - target) < 1 }

        // then — the reveal won, and a later layout pass does not restore the old position.
        pump(turns: 30)
        #expect(abs(row.scroll.documentVisibleRect.minX - target) < 1, "visible \(row.scroll.documentVisibleRect)")
    }

    @Test func givenLayoutNotReady_whenKeyboardFocusEntersALane_thenTheRevealIsKeptAndAppliedOnceLayoutSettles() async throws {
        // given — the document is still the width of two lanes while the row already lists five.
        let row = try await RevealRow.mounted(laneCount: 5, documentLanes: 2)
        defer { row.close() }

        // when — keyboard focus enters lane 2 before layout is ready: nothing can scroll yet.
        row.focus(lane: 2, keyboard: true)
        pump()
        #expect(row.scroll.documentVisibleRect.minX == 0)

        // when — layout settles.
        row.setDocumentLanes(5)
        let target = 3 * ParallelTestGeometry.laneStride - ParallelLayout.dividerWidth + 2 - row.viewportWidth
        await row.settle { abs(row.scroll.documentVisibleRect.minX - target) < 1 }

        // then — the pending reveal was applied, not lost.
        #expect(abs(row.scroll.documentVisibleRect.minX - target) < 1, "visible \(row.scroll.documentVisibleRect)")
    }

    @Test func givenALoadedLane_whenMeasured_thenTheBlockAndTheFeedSitTheDesignGapApart() async throws {
        // given — a lane column with its always-present history caption and a feed.
        _ = NSApplication.shared
        let tests = ParallelVMTests()
        let task = tests.task(id: "gap-lane", status: "completed")
        let rows = [ConversationTimelineRow(id: "gap#1", taskID: task.taskID, timestamp: nil,
                                            kind: .item(PreviewFixtures.textItem("First row", seq: 1)), live: false)]
        let model = ParallelColumnModel(id: task.taskID, task: task, title: "Gap", subtitle: "Claude", isBusy: false,
                                        outcomeMessage: nil, showPrompt: false, prompt: nil, rows: rows,
                                        activityRows: ActivityRowsBuilder.build(from: rows), liveStep: nil, isLoading: false,
                                        summary: nil, onTapTakeover: {}, onTapOpenTask: {})
        let fixture = RedesignHost(ParallelColumnView(model: model).frame(width: 380, height: 600), size: CGSize(width: 380, height: 600))
        defer { fixture.close() }
        await fixture.settle { fixture.element("Available captured history") != nil && fixture.descendants.contains { $0 is ActivityFeedNativeTableView } }
        let caption = try #require(fixture.element("Available captured history"))
        let captionFrame = try #require(fixture.frame(caption))
        let table = try #require(fixture.descendants.compactMap { $0 as? ActivityFeedNativeTableView }.first)
        await fixture.settle { table.numberOfRows > 0 }
        guard case .header = try #require(table.owner?.entries.first) else {
            Issue.record("the lane feed does not open with its header")
            return
        }

        // then — the feed's first entry content starts 12 pt below the block (padding 16 / gap 12 of `.hd-lane__body`).
        // Window coordinates (origin bottom-left): the entry's content top edge against the caption's bottom edge.
        let entryTop = table.convert(table.rect(ofRow: 0), to: nil).maxY - ActivityFeedStyle.lane.topPadding
        let gapBelow = captionFrame.minY - entryTop
        #expect(abs(gapBelow - 12) < 1.5, "block to first feed entry: \(gapBelow)")
    }
}

// MARK: - RevealRow

/// A bare horizontal row: a scroll view, a document of fixed-stride lanes each holding one text field, and the
/// production `ParallelScrollObservationView`. It lets the tests control layout readiness and pending restoration.
@MainActor private final class RevealRow {
    let window: NSWindow
    let scroll: NSScrollView
    let document: RevealDocument
    let observer = ParallelScrollObservationView()
    let ids: [String]
    let viewportWidth: CGFloat = 736
    private var fields: [NSTextField] = []

    final class RevealDocument: NSView { override var isFlipped: Bool { true } }

    static func mounted(laneCount: Int, documentLanes: Int) async throws -> RevealRow {
        let row = RevealRow(laneCount: laneCount, documentLanes: documentLanes)
        row.observer.configure(ids: row.ids, stride: ParallelTestGeometry.laneStride, restorationOffset: nil, restorationActive: false)
        await row.settle { row.scroll.documentVisibleRect.width == row.viewportWidth && row.observer.observedScrollView != nil }
        try #require(row.observer.observedScrollView != nil, "the observer never attached to the row's scroll view")
        return row
    }

    private init(laneCount: Int, documentLanes: Int) {
        _ = NSApplication.shared
        self.ids = (0 ..< laneCount).map { "lane-\($0)" }
        self.scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 736, height: 200))
        scroll.hasHorizontalScroller = true
        self.document = RevealDocument(frame: CGRect(x: 0, y: 0, width: CGFloat(documentLanes) * ParallelTestGeometry.laneStride, height: 200))
        scroll.documentView = document
        for lane in 0 ..< laneCount {
            let field = NSTextField(frame: CGRect(x: CGFloat(lane) * ParallelTestGeometry.laneStride + 20, y: 20, width: 200, height: 24))
            field.placeholderString = "lane \(lane)"
            document.addSubview(field)
            fields.append(field)
        }
        document.addSubview(observer)
        observer.horizontalPosition = ParallelViewportPosition()
        self.window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 736, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
    }

    func setDocumentLanes(_ count: Int) {
        document.setFrameSize(NSSize(width: CGFloat(count) * ParallelTestGeometry.laneStride, height: 200))
    }

    func focus(lane: Int, keyboard: Bool) {
        ParallelScrollObservationView.focusEventType = { keyboard ? .keyDown : .leftMouseDown }
        defer { ParallelScrollObservationView.focusEventType = { NSApp.currentEvent?.type } }
        window.makeFirstResponder(fields[lane])
    }

    func settle(_ predicate: () -> Bool) async {
        await waitUntil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
            return predicate()
        }
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}
