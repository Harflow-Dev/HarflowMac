import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct ActivityFeedNativeScrollerIntentTests {
    @Test(arguments: [NSScroller.Part.decrementLine, .decrementPage, .knob])
    func givenFollowingFeed_whenNativeScrollerActionMovesWithinFollowBand_thenPublicationKeepsActualViewportPaused(part: NSScroller.Part) async throws {
        let state = ParallelColumnUIState()
        let host = NSHostingView(rootView: feed(state, revision: 0))
        let window = activityMountedTestWindow(host, style: [.titled, .resizable])
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 5) { state.viewportPositioned && state.followLive.isFollowing }
        let table = try #require(activityNativeDescendants(host).compactMap { $0 as? ActivityFeedNativeTableView }.first)
        let scroll = try #require(table.enclosingScrollView)
        // Exercise the native action path without entering AppKit's headless mouse tracking loop.
        // Actual mouse delivery remains a separate running-app verification gate.
        let scroller = ScrollerActionFixture(frame: scroll.verticalScroller?.frame ?? .zero)
        scroller.owner = table.owner
        scroll.verticalScroller = scroller
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        scroll.layoutSubtreeIfNeeded()
        scroll.reflectScrolledClipView(scroll.contentView)
        scroll.verticalLineScroll = 23
        scroll.verticalPageScroll = max(0, scroll.contentView.bounds.height - 23)
        let before = scroll.documentVisibleRect.minY
        if part == .knob {
            // Establish the previous native value through the real forwarding action first.
            scroller.fixturePart = .knob
            _ = scroller.sendAction(scroller.action, to: scroller.target)
            let range = table.bounds.height - scroll.contentView.bounds.height
            scroller.doubleValue -= 23 / range
        }
        scroller.fixturePart = part
        try #require(scroller.sendAction(scroller.action, to: scroller.target))
        await waitUntil(timeout: 3) { scroll.documentVisibleRect.minY < before - 3 && !state.followLive.isFollowing }
        let paused = scroll.documentVisibleRect.minY
        try #require(abs(before - paused - 23) < 3, "Public native page action must move within the follow band")
        #expect(!state.followLive.isFollowing)
        host.rootView = feed(state, revision: 1)
        await waitUntil(timeout: 3) { activityNativeCommittedTailStrings(host).contains("Publication 1") }
        #expect(abs(scroll.documentVisibleRect.minY - paused) < 3)
        #expect(!state.followLive.isFollowing)
    }

    private func feed(_ state: ParallelColumnUIState, revision: Int) -> ActivityFeedView {
        let rows = (0 ..< 20).map { index in
            ActivityRow.single(ConversationTimelineRow(id: "scroller-row-\(index)", taskID: "scroller-task", timestamp: nil,
                kind: .item(PreviewFixtures.textItem(String(repeating: "Native scroller reading content. ", count: 10), seq: index)), live: false))
        }
        return ActivityFeedView(rows: rows, start: nil, history: EventHistoryState(), isLoading: false,
            tailValue: ActivityFeedTail(pendingMessages: [PendingMessage(id: "publication", text: "Publication \(revision)")]),
            state: state, onLoadMore: nil, tailPresentation: .plainText("Publication \(revision)"))
    }
}

@MainActor private final class ScrollerActionFixture: ActivityFeedNativeScroller {
    var fixturePart: NSScroller.Part = .noPart
    override var hitPart: NSScroller.Part { fixturePart }
}
