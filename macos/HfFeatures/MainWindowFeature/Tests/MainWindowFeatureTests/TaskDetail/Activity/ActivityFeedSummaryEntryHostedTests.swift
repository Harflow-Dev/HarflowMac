import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
@testable import MonitorCore
import SwiftUI
import Testing

// MARK: - ActivityFeedSummaryEntryHostedTests

/// Hosted behaviour of the Summary entry in the standalone transcript feed: its slot against the displayed height,
/// the reading position when it appears or is removed, following to it at the bottom, and a text change reaching the
/// table.
@MainActor @Suite(.serialized) struct ActivityFeedSummaryEntryHostedTests {
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

    static let taskID = "t1"
    static let summaryID = "t1#summary"
    static let size = NSSize(width: 1000, height: 500)

    // MARK: Fixtures

    private static func prose(_ index: Int) -> ConversationTimelineRow {
        ConversationTimelineRow(
            id: "\(taskID)#\(index)", taskID: taskID, timestamp: nil,
            kind: .item(PreviewFixtures.textItem(String(repeating: "Row \(index) wraps across the transcript reading width. ", count: 5), seq: index)),
            live: false)
    }

    private static func entry(_ text: String) -> ActivityRow {
        let markdown = StreamingMarkdownState().updating(text: text, isStreaming: false)
        return .summary(SummaryEntry(id: summaryID, taskID: taskID, text: text, markdown: markdown))
    }

    private static let longSummary = (1 ... 6)
.map { "Finding \($0) explains one part of the fix in a couple of lines of prose." }
        .joined(separator: "\n\n")

    /// Taller than the viewport, so the reader can rest on the summary without being at the document's end.
    private static let tallSummary = (1 ... 30)
.map { "Paragraph \($0) of a long summary that keeps the entry taller than the viewport." }
        .joined(separator: "\n\n")

    private static func model(_ range: ClosedRange<Int>, summary: String?) -> TimelinePaneModel {
        let conversation = range.map(prose)
        var rows = conversation.map { ActivityRow.single($0, markdown: nil) }
        if let summary { rows.append(entry(summary)) }
        return TimelinePaneModel(
            stepCountText: nil, rows: conversation, activityRows: rows, start: nil, emptyText: nil, subTaskStrip: nil,
            isLoading: false, liveStep: nil, updateToken: ActivityUpdateToken(rows: conversation, liveStep: nil),
            history: EventHistoryState(hasMore: true))
    }

    private func pane(_ model: TimelinePaneModel, state: ParallelColumnUIState) -> some View {
        TimelinePaneView(model: model, state: state, style: .transcript)
            .environment(\.hfReduceMotionOverride, true)
            .frame(width: Self.size.width, height: Self.size.height)
    }

    private func mount(_ model: TimelinePaneModel) async throws -> Mounted {
        _ = NSApplication.shared
        let state = ParallelColumnUIState()
        let host = NSHostingView(rootView: AnyView(pane(model, state: state)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(Self.size)
        window.orderFront(nil)
        await waitUntil(timeout: 8) { state.viewportPositioned }
        let table = try #require(ActivityFeedTranscriptStyleHostedTests.tables(host).first)
        let scroll = try #require(table.enclosingScrollView)
        let owner = try #require(table.owner)
        return Mounted(state: state, host: host, window: window, table: table, scroll: scroll, owner: owner)
    }

    private func pause(_ mounted: Mounted, atRow id: String, inset: CGFloat = 30) async throws {
        let index = try #require(mounted.index(of: id))
        activityNativeTestScroll(mounted.scroll, to: mounted.table.rect(ofRow: index).minY + inset)
        await waitUntil(timeout: 3) { !mounted.state.followLive.isFollowing && mounted.state.anchor != nil }
        try #require(!mounted.state.followLive.isFollowing)
        await waitUntil(timeout: 3) {
            mounted.owner.entries.allSatisfy { entry in
                if case .row(let row) = entry { return !row.fade }
                return true
            }
        }
    }

    /// The summary entry's slot, its displayed host height and the coordinator's off-window measurement.
    private func parity(_ mounted: Mounted) throws -> (slot: CGFloat, drawn: CGFloat, measured: CGFloat) {
        let index = try #require(mounted.index(of: Self.summaryID))
        let box = mounted.owner.boxes[index]
        let cell = try #require(mounted.owner.cells[Self.summaryID], "the summary cell is not realized")
        let host = try #require(cell.host)
        let measured = try #require(mounted.owner.measure(box, width: mounted.owner.currentWidth))
        return (mounted.table.rect(ofRow: index).height, host.fittingSize.height, measured)
    }

    // MARK: Tests

    @Test func givenAFollowingFeed_whenTheSummaryIsMounted_thenItsSlotMatchesItsDisplayedHeight() async throws {
        // given
        let mounted = try await mount(Self.model(1 ... 6, summary: Self.longSummary))
        defer { mounted.close() }
        try #require(mounted.index(of: Self.summaryID) != nil)
        await waitUntil(timeout: 5) { mounted.owner.cells[Self.summaryID]?.host != nil && !mounted.owner.hostedHeightFlushQueued }
        // when
        let measures = try parity(mounted)
        // then
        #expect(abs(measures.drawn - measures.slot) <= 1, "slot \(measures.slot) != drawn \(measures.drawn)")
        #expect(abs(measures.measured - measures.drawn) <= 1, "off-window \(measures.measured) != drawn \(measures.drawn)")
        #expect(measures.slot > 100, "a six paragraph summary must be taller than a divider")
    }

    @Test func givenTheSummaryIsTheLastRow_whenTheEntriesAreRead_thenItPrecedesTheBottomSentinel() async throws {
        // given / when
        let mounted = try await mount(Self.model(1 ... 4, summary: "Fixed it."))
        defer { mounted.close() }
        // then
        let ids = mounted.owner.entries.map(\.id)
        #expect(ids.suffix(2) == [Self.summaryID, "activity-feed-bottom"])
    }

    @Test func givenAReaderScrolledUp_whenTheSummaryAppears_thenTheReadingPositionHolds() async throws {
        // given
        let mounted = try await mount(Self.model(1 ... 40, summary: nil))
        defer { mounted.close() }
        try await pause(mounted, atRow: "t1#20")
        let anchor = try #require(mounted.state.anchor?.id)
        let before = try #require(mounted.relativeOffset(of: anchor))
        // when
        mounted.update(pane(Self.model(1 ... 40, summary: Self.longSummary), state: mounted.state))
        await waitUntil(timeout: 5) { mounted.index(of: Self.summaryID) != nil }
        // then
        try #require(mounted.index(of: Self.summaryID) != nil)
        let after = try #require(mounted.relativeOffset(of: anchor))
        #expect(abs(after - before) < 3, "anchor \(anchor) moved by \(after - before)")
        #expect(!mounted.state.followLive.isFollowing)
        #expect(mounted.table.numberOfRows == mounted.owner.entries.count)
    }

    @Test func givenAFollowingReader_whenTheSummaryAppears_thenTheFeedFollowsToIt() async throws {
        // given
        let mounted = try await mount(Self.model(1 ... 12, summary: nil))
        defer { mounted.close() }
        try #require(mounted.state.followLive.isFollowing)
        // when
        mounted.update(pane(Self.model(1 ... 12, summary: Self.longSummary), state: mounted.state))
        await waitUntil(timeout: 5) { mounted.index(of: Self.summaryID) != nil }
        // then
        let summary = try #require(mounted.index(of: Self.summaryID))
        await waitUntil(timeout: 5) {
            abs(mounted.table.bounds.maxY - mounted.scroll.documentVisibleRect.maxY) < 3
        }
        #expect(abs(mounted.table.bounds.maxY - mounted.scroll.documentVisibleRect.maxY) < 3)
        #expect(mounted.state.followLive.isFollowing)
        let rect = mounted.table.rect(ofRow: summary)
        #expect(rect.intersects(mounted.scroll.documentVisibleRect), "the summary row must be in view")
    }

    @Test func givenAShownSummary_whenItsTextChanges_thenTheTableHoldsTheNewTextAndItsSlotIsRemeasured() async throws {
        // given
        let mounted = try await mount(Self.model(1 ... 6, summary: "Short summary."))
        defer { mounted.close() }
        await waitUntil(timeout: 5) { mounted.owner.cells[Self.summaryID]?.host != nil }
        let before = try #require(mounted.index(of: Self.summaryID)).self
        let heightBefore = mounted.table.rect(ofRow: before).height
        // when
        mounted.update(pane(Self.model(1 ... 6, summary: Self.longSummary), state: mounted.state))
        await waitUntil(timeout: 5) { mounted.table.rect(ofRow: before).height > heightBefore + 20 }
        // then
        let entry = try #require(mounted.owner.entries.first { $0.id == Self.summaryID })
        guard case .row(let value) = entry, case .summary(let summary) = value.row else {
            Issue.record("the summary entry is not a summary row")
            return
        }
        #expect(summary.text == Self.longSummary)
        await waitUntil(timeout: 5) { mounted.owner.cells[Self.summaryID]?.host?.rootView.entry == entry }
        let measures = try parity(mounted)
        #expect(abs(measures.drawn - measures.slot) <= 1, "slot \(measures.slot) != drawn \(measures.drawn)")
        #expect(mounted.table.rect(ofRow: before).height > heightBefore + 20)
    }

    @Test func givenTheSummaryIsTheReadingAnchor_whenAFollowUpBecomesCurrent_thenReadingLandsOnThePreviousRow() async throws {
        // given — the reader is paused on the summary itself.
        let mounted = try await mount(Self.model(1 ... 40, summary: Self.tallSummary))
        defer { mounted.close() }
        try await pause(mounted, atRow: Self.summaryID, inset: 4)
        await waitUntil(timeout: 3) { mounted.state.anchor?.id == Self.summaryID }
        try #require(mounted.state.anchor?.id == Self.summaryID, "the summary must be the reading anchor, was \(String(describing: mounted.state.anchor?.id))")
        // when — the summary is removed structurally: the follow-up's rows replace the end of the run.
        mounted.update(pane(Self.model(1 ... 40, summary: nil), state: mounted.state))
        await waitUntil(timeout: 5) { mounted.index(of: Self.summaryID) == nil }
        // then — reading is kept at the surviving previous row, not lost to the top or reset to following.
        try #require(mounted.index(of: Self.summaryID) == nil)
        await waitUntil(timeout: 5) { mounted.state.anchor?.id != Self.summaryID }
        let previous = "t1#40"
        let visible = mounted.scroll.documentVisibleRect
        // Forty rows keep the first row far above any viewport near the end, so a fallback to the earliest row fails.
        let first = try #require(mounted.index(of: "t1#1"))
        #expect(!mounted.table.rect(ofRow: first).intersects(visible), "reading must not jump to the earliest row")
        let row = try #require(mounted.index(of: previous))
        #expect(mounted.table.rect(ofRow: row).intersects(visible), "the previous row must be in view")
        let anchor = try #require(mounted.state.anchor, "the reading anchor was lost")
        #expect(anchor.id != Self.summaryID)
        #expect(mounted.index(of: anchor.id) != nil, "anchor \(anchor.id) is not a surviving row")
        #expect(!mounted.state.followLive.isFollowing, "reading must not turn into following")
        #expect(mounted.table.numberOfRows == mounted.owner.entries.count)
    }
}
