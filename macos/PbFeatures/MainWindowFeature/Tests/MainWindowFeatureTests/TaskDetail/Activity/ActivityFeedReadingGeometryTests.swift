import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import SwiftUI
import Testing

// MARK: - ActivityFeedReadingGeometryTests

@MainActor @Suite(.serialized) struct ActivityFeedReadingGeometryTests {
    @Test func givenPausedExpandedToolAnchor_whenWidthChangesAndOlderCallsPrepend_thenVisibleRowPositionIsPreserved() async throws {
        // given — locate the actual measured group through native reading movement.
        _ = NSApplication.shared
        let state = ParallelColumnUIState()
        let originalID = "tool-first"
        state.expandedGroups = [originalID]
        let host = NSHostingView(rootView: feed(rows(prepending: false), state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil { @MainActor in state.viewportPositioned }
        try #require(state.viewportPositioned, "Initial positioning must settle before reading movement")
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
        for offset in stride(from: CGFloat(0), through: 1000, by: 10) {
            scroll.contentView.scroll(to: CGPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            await waitUntil { @MainActor in abs(state.scrollOffset - offset) < 1 && !state.followLive.isFollowing }
            if state.anchor?.id == originalID { break }
        }
        var anchor = try #require(state.anchor)
        #expect(anchor.id == originalID)
        #expect(!state.followLive.isFollowing)
        // when — resize while reading, then nudge to force fresh measured geometry capture.
        for width: CGFloat in [700, 340] {
            let previousWidth = scroll.contentView.bounds.width
            window.setContentSize(CGSize(width: width, height: 450))
            await waitUntil(timeout: 5) { @MainActor in
                state.viewportPositioned && abs(scroll.contentView.bounds.width - previousWidth) > 10
            }
            anchor = try await recapture(scroll: scroll, state: state, expected: anchor)
        }
        // Overlap successive restoration requests while native measurement callbacks are queued.
        // Metrics are disabled by default: generation changes must themselves invalidate the view.
        for width: CGFloat in [350, 360, 340] {
            window.setContentSize(CGSize(width: width, height: 450))
            host.rootView = feed(rows(prepending: true), state: state)
            window.layoutIfNeeded()
            await Task.yield()
        }
        var previousGeometry: [CGFloat] = []
        var stableReports = 0
        await waitUntil(timeout: 5) { @MainActor in
            let geometry = [scroll.contentView.bounds.width, scroll.documentView?.bounds.height ?? 0,
                            scroll.documentVisibleRect.minY]
            stableReports = geometry == previousGeometry ? stableReports + 1 : 0
            previousGeometry = geometry
            return stableReports >= 3 && state.viewportPositioned && state.anchor?.id == "tool-older"
                && abs(scroll.contentView.bounds.width - 340) < 1
        }
        let replacement = ParallelVerticalAnchor(id: "tool-older", index: anchor.index, relativeOffset: anchor.relativeOffset)
        _ = try await recapture(scroll: scroll, state: state, expected: replacement)
        // then — logical identity and expansion migrate with the actual visible position.
        #expect(!state.followLive.isFollowing)
        #expect(state.anchor?.id == "tool-older")
        #expect(state.expandedGroups.contains("tool-older"))
        #expect(!state.expandedGroups.contains(originalID))
    }

    @Test func givenPartiallyVisibleParallelFeed_whenNativeAttachmentIsDelayed_thenRowsRealizeWithoutScrolling() async throws {
        _ = NSApplication.shared
        let states = (0 ..< 3).map { _ in ParallelColumnUIState() }
        let activity = rows(prepending: false)
        let host = NSHostingView(rootView: ScrollView(.horizontal) {
            LazyHStack(spacing: 1) {
                ForEach(0 ..< 3, id: \.self) { index in
                    feed(activity, state: states[index]).frame(width: 420)
                }
            }
        })
        host.frame = CGRect(x: 0, y: 0, width: 950, height: 450)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 5) { states[2].viewportPositioned }
        #expect(states[2].viewportPositioned)
        let vertical = descendants(host).compactMap { $0 as? NSScrollView }.filter(\.hasVerticalScroller)
        #expect(vertical.count >= 3)
        let scroll = try #require(vertical.last)
        let document = try #require(scroll.documentView)
        let realized = descendants(document).filter { String(describing: type(of: $0)).contains("MeasurementView") }
        let visibleRows = realized.filter { $0.convert($0.bounds, to: document).intersects(scroll.documentVisibleRect) }
        #expect(!visibleRows.isEmpty, "Partially visible feed must realize row content before any user scrolling")
    }

    private func recapture(scroll: NSScrollView, state: ParallelColumnUIState,
                           expected: ParallelVerticalAnchor) async throws -> ParallelVerticalAnchor {
        let previous = state.anchor
        let offset = scroll.documentVisibleRect.minY + 1
        scroll.contentView.scroll(to: CGPoint(x: 0, y: offset))
        scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil { @MainActor in state.anchor != previous && abs(state.scrollOffset - offset) < 1 }
        let measured = try #require(state.anchor)
        #expect(measured != previous, "Native reading movement must recapture current row geometry")
        #expect(measured.id == expected.id)
        #expect(abs(measured.relativeOffset - expected.relativeOffset + 1) < 3)
        #expect(state.viewportPositioned)
        #expect(!state.followLive.isFollowing)
        return measured
    }

    private func feed(_ rows: [ActivityRow], state: ParallelColumnUIState) -> some View {
        ActivityFeedView(rows: rows, start: nil, history: EventHistoryState(), isLoading: false,
                         horizontalPadding: 24, state: state, onLoadMore: nil) { EmptyView() }.readingColumn()
    }

    private func rows(prepending: Bool) -> [ActivityRow] {
        let before = ConversationTimelineRow(id: "before", taskID: "synthetic", timestamp: nil,
            kind: .item(PreviewFixtures.textItem(String(repeating: "Synthetic preceding text reflows at different widths.\n\n", count: 4))), live: false)
        let after = ConversationTimelineRow(id: "after", taskID: "synthetic", timestamp: nil,
            kind: .item(PreviewFixtures.textItem(
                String(repeating: "Synthetic following activity keeps the reading position away from the end.\n\n", count: 60), seq: 100)), live: false)
        let ids = prepending ? ["tool-older", "tool-first", "tool-second"] : ["tool-first", "tool-second"]
        let calls = ids.enumerated().map { index, id in
            ConversationTimelineRow(id: id, taskID: "synthetic", timestamp: nil,
                kind: .item(PreviewFixtures.toolItem(outputTail: String(repeating: "Synthetic output line that wraps at the reading width.\n", count: 12),
                    seq: index * 2 + 10, callID: id)), live: false)
        }
        return ActivityRowsBuilder.build(from: [before] + calls + [after])
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
