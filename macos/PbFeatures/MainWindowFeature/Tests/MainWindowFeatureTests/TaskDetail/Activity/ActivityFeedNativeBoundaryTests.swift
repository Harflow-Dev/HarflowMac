import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct ActivityFeedNativeBoundaryTests {
    @Test func givenFollowingFeed_whenNativeMovesNearBottom_thenBoundaryAndLiveIntentArePreserved() async throws {
        // given — a settled feed at the live bottom with stable native geometry.
        _ = NSApplication.shared
        let state = ParallelColumnUIState()
        let host = NSHostingView(rootView: feed(state: state))
        let window = activityMountedTestWindow(host, style: [.titled, .resizable])
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 5) { @MainActor in state.viewportPositioned && state.followLive.isFollowing }
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first { $0.hasVerticalScroller })
        let document = try #require(scroll.documentView)
        let bottom = bottomOrigin(scroll: scroll, document: document)
        scroll.contentView.scroll(to: bottom)
        scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil(timeout: 5) { @MainActor in
            state.followLive.isFollowing && scroll.documentVisibleRect.maxY >= document.bounds.maxY - 2
        }
        let viewportSize = scroll.contentView.bounds.size
        let documentHeight = document.bounds.height

        // when — native movement crosses the follow tolerance, including an active live gesture.
        for delta in [CGFloat(23), 24, 25] {
            scroll.contentView.scroll(to: bottom)
            scroll.reflectScrolledClipView(scroll.contentView)
            await waitUntil(timeout: 5) { @MainActor in
                state.followLive.isFollowing && scroll.documentVisibleRect.maxY >= document.bounds.maxY - 2
            }
            let bottomOffset = scroll.documentVisibleRect.minY
            scroll.contentView.scroll(to: CGPoint(x: bottom.x, y: max(0, bottom.y - delta)))
            scroll.reflectScrolledClipView(scroll.contentView)
            let movedOffset = scroll.documentVisibleRect.minY
            #expect(abs(movedOffset - bottomOffset + delta) < 2)
            if delta > 24 {
                await waitUntil(timeout: 5) { @MainActor in
                    state.viewportPositioned && scroll.contentView.bounds.size == viewportSize
                        && abs(document.bounds.height - documentHeight) < 1
                        && abs(scroll.documentVisibleRect.minY - bottomOffset + delta) < 2
                }
            }
            if delta <= 24 {
                await waitUntil(timeout: 5) { @MainActor in
                    state.viewportPositioned && state.followLive.isFollowing
                        && document.bounds.maxY - scroll.documentVisibleRect.maxY < 1
                }
            }
            let gap = document.bounds.maxY - scroll.documentVisibleRect.maxY
            if delta <= 24 {
                #expect(state.followLive.isFollowing)
                #expect(gap < 1, "Near-bottom native movement must rearm the live bottom")
            } else {
                #expect(!state.followLive.isFollowing)
                #expect(abs(gap - delta) < 2, "Movement beyond tolerance must pause")
                try await observePausedGap(scroll: scroll, document: document,
                                           bottomOffset: bottomOffset, delta: delta, state: state)
            }
            if delta == 23 {
                try await exerciseLiveIntent(scroll: scroll, bottom: bottom,
                                             bottomOffset: bottomOffset, delta: delta, state: state)
                // An upward live-intent move remains paused until a stable downward move
                // re-enters the bottom zone; the later near-bottom reenable is directional.
                try await observePausedGap(scroll: scroll, document: document,
                                           bottomOffset: bottomOffset, delta: delta, state: state)
            }
        }

        // then — near-bottom movement re-pins, larger movement pauses, and live intent remains visible.
    }

    private func exerciseLiveIntent(scroll: NSScrollView, bottom: CGPoint,
                                    bottomOffset: CGFloat, delta: CGFloat,
                                    state: ParallelColumnUIState) async throws {
        defer {
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification,
                                            object: scroll)
        }
        let document = try #require(scroll.documentView)
        scroll.contentView.scroll(to: bottom)
        scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil(timeout: 5) { @MainActor in
            state.followLive.isFollowing && scroll.documentVisibleRect.maxY >= document.bounds.maxY - 2
        }
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: CGPoint(x: bottom.x, y: max(0, bottom.y - delta)))
        scroll.reflectScrolledClipView(scroll.contentView)
        for _ in 0 ..< 10 {
            try #require(abs(scroll.documentVisibleRect.minY - bottomOffset + delta) < 2)
            #expect(document.bounds.maxY - scroll.documentVisibleRect.maxY > 20,
                    "A live-intent move must remain visible before any later near-bottom reenable")
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func observePausedGap(scroll: NSScrollView, document: NSView,
                                  bottomOffset: CGFloat, delta: CGFloat,
                                  state: ParallelColumnUIState) async throws {
        for _ in 0 ..< 10 {
            try #require(!state.followLive.isFollowing)
            try #require(abs(scroll.documentVisibleRect.minY - bottomOffset + delta) < 2)
            try #require(document.bounds.maxY - scroll.documentVisibleRect.maxY > 20)
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func feed(state: ParallelColumnUIState) -> some View {
        ActivityFeedView(rows: rows(), start: nil, history: EventHistoryState(), isLoading: false,
                         horizontalPadding: 24, state: state, onLoadMore: nil).readingColumn()
    }

    private func rows() -> [ActivityRow] {
        let before = ConversationTimelineRow(id: "before", taskID: "synthetic", timestamp: nil,
            kind: .item(PreviewFixtures.textItem(String(repeating: "Synthetic preceding text.\n\n", count: 4))), live: false)
        let calls = (0 ..< 3).map { index in
            ConversationTimelineRow(id: "tool-\(index)", taskID: "synthetic", timestamp: nil,
                kind: .item(PreviewFixtures.toolItem(outputTail: String(repeating: "Synthetic output line.\n", count: 12),
                    seq: index * 2 + 10, callID: "tool-\(index)")), live: false)
        }
        let after = ConversationTimelineRow(id: "after", taskID: "synthetic", timestamp: nil,
            kind: .item(PreviewFixtures.textItem(String(repeating: "Synthetic following activity.\n\n", count: 60), seq: 100)), live: false)
        return ActivityRowsBuilder.build(from: [before] + calls + [after])
    }

    private func bottomOrigin(scroll: NSScrollView, document: NSView) -> CGPoint {
        let bottom = document.bounds.maxY - scroll.contentView.bounds.height
        return scroll.contentView
.constrainBoundsRect(
            CGRect(origin: CGPoint(x: scroll.contentView.bounds.minX, y: bottom),
                   size: scroll.contentView.bounds.size)
        )
.origin
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
