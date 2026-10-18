import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct ActivityFeedViewTests {
    private func rows(_ count: Int, from: Int = 0) -> [ActivityRow] {
        (from ..< from + count).map { index in
            .single(ConversationTimelineRow(id: "row\(index)", taskID: "task", timestamp: nil,
                kind: .item(PreviewFixtures.textItem(String(repeating: "Activity \(index) is preserved. ", count: 8), seq: index)), live: false))
        }
    }

    @Test func givenLongLoadedHistory_whenOpeningAndScrollingUp_thenInitialBottomAndBoundedOlderRevealAreUsed() async throws {
        // given
        _ = NSApplication.shared
        let state = ParallelColumnUIState()
        let values = rows(250)
        let host = NSHostingView(rootView: ActivityFeedView(rows: values, start: nil, history: EventHistoryState(), isLoading: false,
            state: state, onLoadMore: nil).frame(width: 420, height: 450))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil { host.layoutSubtreeIfNeeded(); return state.anchor != nil && state.scrollOffset > 500 }
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
        #expect(state.retainedFirstID == nil)
        #expect(abs(scroll.documentVisibleRect.maxY - (scroll.documentView?.bounds.maxY ?? 0)) < 3)
        // when
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil { host.layoutSubtreeIfNeeded(); return state.retainedFirstID == "row50" }
        // then
        #expect(state.retainedFirstID == "row50")
        #expect(!state.followLive.isFollowing)
        #expect(state.anchor != nil)
    }

    @Test func givenNeighborOrError_whenShortFeedMounts_thenNoAutomaticPageRequestOccurs() async throws {
        // given
        _ = NSApplication.shared
        let requests = Requests()
        let state = ParallelColumnUIState()
        let host = NSHostingView(rootView: ActivityFeedView(rows: rows(1), start: nil,
            history: EventHistoryState(hasMore: true), isLoading: false, isVisible: false,
            state: state, onLoadMore: { requests.total += 1; return true }).frame(width: 420, height: 450))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil { host.layoutSubtreeIfNeeded(); return state.anchor != nil }
        // when
        host.rootView = ActivityFeedView(rows: rows(1), start: nil, history: EventHistoryState(hasMore: true, error: "read failed"),
            isLoading: false, isVisible: true, state: state, onLoadMore: { requests.total += 1; return true }).frame(width: 420, height: 450)
        await waitUntil { host.layoutSubtreeIfNeeded(); return descendants(host).contains { ($0 as? NSTextField)?.stringValue == "read failed" } }
        // then
        #expect(requests.total == 0)
    }

    @Test func givenShortVisibleFeed_whenItsThresholdRepeats_thenOnlyOneRequestIsOutstanding() async throws {
        // given
        _ = NSApplication.shared
        let requests = Requests()
        let state = ParallelColumnUIState()
        let host = NSHostingView(rootView: ActivityFeedView(rows: rows(1), start: nil, history: EventHistoryState(hasMore: true), isLoading: false,
            state: state, onLoadMore: { requests.total += 1; return true }).frame(width: 420, height: 450))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil { host.layoutSubtreeIfNeeded(); return requests.total == 1 }
        // when
        window.setContentSize(CGSize(width: 420, height: 460)); host.layoutSubtreeIfNeeded()
        // then
        #expect(requests.total == 1)
    }

    @Test func givenFollowingLatest_whenOnlyPendingTailChanges_thenTheNewTailRemainsVisible() async throws {
        // given
        _ = NSApplication.shared
        let state = ParallelColumnUIState()
        let values = rows(12)
        let host = NSHostingView(rootView: tailFixture(rows: values, state: state, text: ""))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil { host.layoutSubtreeIfNeeded(); return state.anchor != nil && state.scrollOffset > 100 }
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
        let previousHeight = scroll.documentView?.bounds.height ?? 0
        // when
        host.rootView = tailFixture(rows: values, state: state, text: String(repeating: "Pending activity text.\n", count: 60))
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            return (scroll.documentView?.bounds.height ?? 0) > previousHeight + 500
                && abs(scroll.documentVisibleRect.maxY - (scroll.documentView?.bounds.maxY ?? 0)) < 3
        }
        // then
        #expect(state.followLive.isFollowing)
        #expect(abs(scroll.documentVisibleRect.maxY - (scroll.documentView?.bounds.maxY ?? 0)) < 3)
    }

    @Test func givenStaticPlainTextTail_whenFeedMounts_thenTailAndSentinelParticipateInDocument() async throws {
        _ = NSApplication.shared
        enableAccessibility()
        let state = ParallelColumnUIState()
        let host = NSHostingView(rootView: tailFixture(rows: rows(12), state: state, text: "Static tail content"))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        await waitUntil {
            host.layoutSubtreeIfNeeded()
            return state.viewportPositioned && activityNativeTailPrerequisite(host) && committedTailStrings(in: host).contains("Static tail content")
        }
        try #require(committedTailStrings(in: host).contains("Static tail content"))
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
        #expect((scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height)
        #expect(state.followLive.isFollowing)
    }

    @Test func givenReadingUpward_whenPlainTextTailChanges_thenLatestTailCommitsWithoutResumingFollowAndRendersWhenRevealed() async throws {
        _ = NSApplication.shared
        enableAccessibility()
        let state = ParallelColumnUIState()
        let values = rows(24)
        let host = NSHostingView(rootView: tailFixture(rows: values, state: state, text: "Initial tail"))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        await waitUntil { host.layoutSubtreeIfNeeded(); return state.viewportPositioned && state.anchor != nil }
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 180)); scroll.reflectScrolledClipView(scroll.contentView)
        var gestureReady = false
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            gestureReady = !state.followLive.isFollowing && state.anchor != nil
                && abs(scroll.documentVisibleRect.minY - 180) < 4
                && abs(state.scrollOffset - 180) < 4
            return gestureReady
        }
        try #require(gestureReady, "The upward gesture must settle at the requested offset before tail mutation")
        let anchor = try #require(state.anchor)

        host.rootView = tailFixture(rows: values, state: state, text: String(repeating: "Updated live tail.\n", count: 20))
        await Task.yield()
        #expect(!state.followLive.isFollowing)
        #expect(state.anchor?.id == anchor.id)
        #expect(abs(scroll.documentVisibleRect.minY - 180) < 4)
        activityNativeRevealBottom(scroll)
        await waitUntil { committedTailStrings(in: host).contains { $0.contains("Updated live tail.") } }
        try #require(committedTailStrings(in: host).contains { $0.contains("Updated live tail.") })
    }

    @Test func givenSemanticTailAndPresentation_whenCheckingTailVisibility_thenAbsentAndEmptyAreOmitted() {
        let semanticTail = ActivityFeedTail(pendingMessages: [PendingMessage(id: "pending", text: "queued")])
        #expect(ActivityFeedTailPresentation.absent.isVisible(with: semanticTail) == false)
        #expect(ActivityFeedTailPresentation.plainText("queued").isVisible(with: semanticTail))
        #expect(ActivityFeedTailPresentation.standard(.init()).isVisible(with: ActivityFeedTail()) == false)
    }

    @Test func givenReadingOlderRows_whenHistoryPrependsAndLiveRowsArrive_thenVisibleAnchorAndOffsetRemainStable() async throws {
        // given
        _ = NSApplication.shared
        let state = ParallelColumnUIState()
        let requests = Requests()
        let values = rows(150, from: 100)
        let host = NSHostingView(rootView: ActivityFeedView(rows: values, start: nil, history: EventHistoryState(hasMore: true), isLoading: false,
            state: state, onLoadMore: { requests.total += 1; return true }).frame(width: 420, height: 450))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil { host.layoutSubtreeIfNeeded(); return state.anchor != nil && state.scrollOffset > 500 }
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
        let readingOffset: CGFloat = 100
        scroll.contentView.scroll(to: CGPoint(x: 0, y: readingOffset)); scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil { abs(state.scrollOffset - readingOffset) < 2 && !state.followLive.isFollowing && requests.total == 1 }
        let anchor = try #require(state.anchor)
        // when
        host.rootView = ActivityFeedView(rows: rows(120, from: -120) + values + rows(1, from: 250), start: nil,
            history: EventHistoryState(), isLoading: false, paginationRevision: 1, state: state, onLoadMore: nil).frame(width: 420, height: 450)
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            return abs(scroll.documentVisibleRect.minY - readingOffset) > 100 && state.anchor?.id == anchor.id
        }
        let restoredOffset = scroll.documentVisibleRect.minY
        scroll.contentView.scroll(to: CGPoint(x: 0, y: restoredOffset + 1)); scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil { abs(state.scrollOffset - restoredOffset - 1) < 2 }
        // then
        #expect(state.anchor?.id == anchor.id)
        #expect(abs((state.anchor?.relativeOffset ?? .infinity) - anchor.relativeOffset + 1) < 3)
        #expect(!state.followLive.isFollowing)
    }

    @Test func givenShortSuccessfulPages_whenCommittedWithoutNewScrollIntent_thenAutomaticFillDoesNotDrainHistory() async throws {
        _ = NSApplication.shared
        let requests = Requests()
        let state = ParallelColumnUIState()
        let history = EventHistoryState(hasMore: true)
        let host = NSHostingView(rootView: ActivityFeedView(rows: rows(1), start: nil, history: history, isLoading: false,
            state: state, onLoadMore: { requests.total += 1; return true }).frame(width: 420, height: 450))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil { host.layoutSubtreeIfNeeded(); return requests.total == 1 }
        // A valid page can advance its cursor without adding a visible row.
        host.rootView = ActivityFeedView(rows: rows(1), start: nil, history: history, isLoading: false, paginationRevision: 1,
            state: state, onLoadMore: { requests.total += 1; return true }).frame(width: 420, height: 450)
        await waitUntil { host.layoutSubtreeIfNeeded(); return state.viewportPositioned }
        for _ in 0 ..< 20 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        #expect(requests.total == 1)
        let nativeScroll = try #require(descendants(host).compactMap { $0 as? ActivityFeedNativeScrollView }.first)
        nativeScroll.owner?.noteUpwardIntent()
        await waitUntil { host.layoutSubtreeIfNeeded(); return requests.total == 2 }
        #expect(requests.total == 2)
    }

    @Test func givenShortFillBudget_whenUpwardIntentOrDisclosureReplenishes_thenExactlyOneMorePageIsAllowed() {
        var budget = ActivityShortFillBudget()
        let consumed1 = budget.consume(content: 100, viewport: 450)
        #expect(consumed1)
        let consumed2 = !budget.consume(content: 100, viewport: 450)
        #expect(consumed2)
        budget.replenish()
        let consumed3 = budget.consume(content: 100, viewport: 450)
        #expect(consumed3)
        let consumed4 = !budget.consume(content: 100, viewport: 450)
        #expect(consumed4)
        // Ordinary scrollable feeds remain driven by the 200-point threshold.
        let consumed5 = budget.consume(content: 1000, viewport: 450)
        #expect(consumed5)
        budget.replenish()
        let consumed6 = budget.consume(content: 100, viewport: 450)
        #expect(consumed6)
    }

    @Test func givenPausedFeed_whenHistoryResetsToEmpty_thenRestorationSettlesAndNewRowsCanBeRead() async throws {
        _ = NSApplication.shared
        let state = ParallelColumnUIState()
        let host = NSHostingView(rootView: ActivityFeedView(rows: rows(80), start: nil, history: EventHistoryState(), isLoading: false,
            state: state, onLoadMore: nil).frame(width: 420, height: 450))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            return state.anchor != nil && state.viewportPositioned && state.scrollOffset > 500
        }
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 400)); scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil { abs(state.scrollOffset - 400) < 2 && !state.followLive.isFollowing }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        var settledAnchor: ParallelVerticalAnchor?
        var stableSamples = 0
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            let current = state.anchor
            if current == settledAnchor {
                stableSamples += 1
            } else {
                settledAnchor = current
                stableSamples = 0
            }
            return stableSamples >= 2 && current != nil && !state.followLive.isFollowing
        }
        try #require(state.anchor != nil && !state.followLive.isFollowing,
                     "The reading anchor must settle while the feed is paused before replacing history")
        #expect(state.anchor != nil)
        host.rootView = ActivityFeedView(rows: [], start: nil, history: EventHistoryState(), isLoading: false,
            state: state, onLoadMore: nil).frame(width: 420, height: 450)
        await waitUntil { host.layoutSubtreeIfNeeded(); return state.viewportPositioned && state.anchor == nil }
        #expect(state.viewportPositioned)
        #expect(state.anchor == nil)
        #expect(state.retainedFirstID == nil)
        #expect(abs(scroll.documentVisibleRect.minY) < 1)
        #expect(!state.followLive.isFollowing)
        host.rootView = ActivityFeedView(rows: rows(3, from: 100), start: nil, history: EventHistoryState(), isLoading: false,
            state: state, onLoadMore: nil).frame(width: 420, height: 450)
        await waitUntil { host.layoutSubtreeIfNeeded(); return state.viewportPositioned && state.anchor != nil }
        #expect(state.viewportPositioned)
        #expect(state.anchor?.id == "row100")
    }

    @Test func givenRejectedPageRequest_whenPresentationWasStale_thenFeedDoesNotRemainLoading() async throws {
        _ = NSApplication.shared
        let requests = Requests()
        let state = ParallelColumnUIState()
        let host = NSHostingView(rootView: ActivityFeedView(rows: rows(1), start: nil, history: EventHistoryState(hasMore: true), isLoading: false,
            state: state, onLoadMore: { requests.total += 1; return false }).frame(width: 420, height: 450))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil { host.layoutSubtreeIfNeeded(); return requests.total == 1 && state.viewportPositioned }
        for _ in 0 ..< 20 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        #expect(requests.total == 1)
        #expect(state.viewportPositioned)
        #expect(!descendants(host).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Loading activity…" })
    }

    private func tailFixture(rows: [ActivityRow], state: ParallelColumnUIState, text: String) -> some View {
        ActivityFeedView(rows: rows, start: nil, history: EventHistoryState(), isLoading: false,
            tailValue: ActivityFeedTail(pendingMessages: [PendingMessage(id: "pending", text: text)]),
            state: state, onLoadMore: nil, tailPresentation: .plainText(text)).frame(width: 420, height: 450)
    }

    private final class Requests { var total = 0 }
    private func enableAccessibility() {
        NSApplication.shared.accessibilitySetValue(true,
            forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func committedTailStrings(in host: NSView) -> Set<String> {
        activityNativeCommittedTailStrings(host)
    }
}
