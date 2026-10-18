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
        let window = activityMountedTestWindow(host, style: [.titled, .resizable])
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
        let realized = descendants(document).filter { ($0 as? ActivityFeedNativeCell)?.isCoherentNativeMeasurement == true }
        let visibleRows = realized.filter { $0.convert($0.bounds, to: document).intersects(scroll.documentVisibleRect) }
        #expect(!visibleRows.isEmpty, "Partially visible feed must realize row content before any user scrolling")
    }

    @Test func givenPausedAnchor_whenTwoResizesArriveBeforeFreshMeasurement_thenLatestViewportRestoresAnchor() async throws {
        // given — establish a real paused anchor with a mounted measurement.
        _ = NSApplication.shared
        let state = ParallelColumnUIState()
        let host = NSHostingView(rootView: feed(rows(prepending: false), state: state))
        let window = activityMountedTestWindow(host, style: [.titled, .resizable])
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 5) { @MainActor in state.viewportPositioned }
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first { $0.hasVerticalScroller })
        for offset in stride(from: CGFloat(0), through: 900, by: 10) {
            scroll.contentView.scroll(to: CGPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            await waitUntil(timeout: 5) { @MainActor in
                abs(state.scrollOffset - offset) < 1 && !state.followLive.isFollowing
            }
            if state.anchor?.id == "tool-first" { break }
        }
        let anchor = try #require(state.anchor)
        try #require(anchor.id == "tool-first")
        let initialFrame = try #require(measurementFrame(for: anchor, in: host, scroll: scroll))
        let initialViewportWidth = scroll.contentView.bounds.width

        // when — resize twice before yielding to the queued measurement callbacks. The second
        // callback must advance from the first pending width, while stale B geometry is rejected.
        window.setContentSize(CGSize(width: 700, height: 450))
        window.setContentSize(CGSize(width: 340, height: 450))
        await Task.yield()

        // then — the final C viewport restores the same semantic row and remains paused.
        await waitUntil(timeout: 5) { @MainActor in
            state.viewportPositioned && !state.followLive.isFollowing
                && state.anchor?.id == anchor.id
                && abs(scroll.contentView.bounds.width - 340) < 1
        }
        let finalDocument = try #require(scroll.documentView)
        let finalFrame = try #require(measurementFrame(for: anchor, in: host, scroll: scroll))
        #expect(!state.followLive.isFollowing)
        #expect(state.anchor?.id == anchor.id)
        let expectedFinalWidth = initialFrame.width + scroll.contentView.bounds.width - initialViewportWidth
        #expect(abs(finalFrame.width - expectedFinalWidth) < 3)
        #expect(abs(finalFrame.minY - scroll.documentVisibleRect.minY - anchor.relativeOffset) < 3)
        #expect(finalDocument.bounds.height > scroll.contentView.bounds.height)
    }

    @Test func givenPausedLiveActivityFeed_whenPrependingHistoryArrives_thenReadingPositionIsPreserved() async throws {
        _ = NSApplication.shared
        let state = ParallelColumnUIState()
        let host = NSHostingView(rootView: feed(rows(prepending: false), state: state))
        let window = activityMountedTestWindow(host, style: [.titled, .resizable])
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 5) { @MainActor in state.viewportPositioned && state.followLive.isFollowing }
        try #require(state.viewportPositioned && state.followLive.isFollowing,
                     "The feed must finish initial positioning while still following live output")
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first { $0.hasVerticalScroller })
        let document = try #require(scroll.documentView)
        let legalBottom = scroll.contentView
.constrainBoundsRect(
            CGRect(origin: CGPoint(x: scroll.contentView.bounds.minX,
                                   y: document.bounds.maxY - scroll.contentView.bounds.height),
                   size: scroll.contentView.bounds.size))
.origin
        scroll.contentView.scroll(to: legalBottom)
        scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil(timeout: 5) {
            @MainActor in state.viewportPositioned && state.followLive.isFollowing
                && scroll.documentVisibleRect.maxY >= document.bounds.maxY - 2
        }
        try #require(state.viewportPositioned && state.followLive.isFollowing
                         && scroll.documentVisibleRect.maxY >= document.bounds.maxY - 2,
                     "The feed must settle at the live bottom before pausing")
        let initialOffset = scroll.documentVisibleRect.minY
        let liveAnchor = try #require(state.anchor)

        // Explicitly pause the feed, then move the native viewport to the reading position.
        state.followLive.suspend()
        try #require(!state.followLive.isFollowing)
        let target = max(0, initialOffset - 180)
        scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.minX, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil(timeout: 5) {
            @MainActor in !state.followLive.isFollowing && state.anchor != nil
                && state.anchor != liveAnchor
                && abs(state.scrollOffset - scroll.documentVisibleRect.minY) < 2
                && scroll.documentVisibleRect.minY <= initialOffset - 24
        }
        try #require(!state.followLive.isFollowing && state.anchor != nil
                         && state.anchor != liveAnchor
                         && abs(state.scrollOffset - scroll.documentVisibleRect.minY) < 2
                         && scroll.documentVisibleRect.minY <= initialOffset - 24,
                     "The paused feed must record a meaningful upward reading position")
        let pausedAnchor = try #require(state.anchor)
        let pausedViewport = scroll.documentVisibleRect
        let pausedRowFrame = try #require(firstVisibleMeasurementFrame(in: host, scroll: scroll),
                                          "The paused anchor must have a mounted row measurement")
        #expect(abs(pausedRowFrame.minY - pausedViewport.minY - pausedAnchor.relativeOffset) < 3,
                "The captured anchor must describe the measured row's position in the viewport")
        let generationBeforePublication = measurementGeneration(in: host)

        host.rootView = feed(rows(prepending: true), state: state)
        try await verifyPublishedHistory(host: host, state: state, scroll: scroll,
                                               pausedAnchor: pausedAnchor,
                                               generationBeforePublication: generationBeforePublication)
    }

    @Test func givenAPausedActivityFeed_whenLegacyChromeIsReasserted_thenReadingAnchorAndFollowStateSurvive() async throws {
        // given — this is the real ActivityFeedView used by Task detail, Parallel lanes and
        // Workflow activity. Start paused so the test checks semantic reading, not live-bottom.
        _ = NSApplication.shared
        let state = ParallelColumnUIState()
        state.followLive.suspend()
        let host = NSHostingView(rootView: feed(rows(prepending: false), state: state))
        let window = activityMountedTestWindow(host, style: [.titled, .resizable])
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 5) { @MainActor in state.viewportPositioned }
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first { $0.hasVerticalScroller })

        // when — establish a paused, scrolled-away reading anchor before native chrome changes.
        let targetOffset = max(1, scroll.documentVisibleRect.minY + 180)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: targetOffset))
        scroll.reflectScrolledClipView(scroll.contentView)
        let anchor = try await requireFreshPausedAnchor(host: host, scroll: scroll, state: state, targetOffset: targetOffset)
        let originalGroup = try requireOriginalGroup(anchor: anchor)
        let originalMemberIDs = Set(originalGroup.members.map(\.id))
        let offsetBeforeChrome = scroll.documentVisibleRect.minY

        // when — exercise the production lifecycle after the existing viewport observer is live.
        scroll.scrollerStyle = .legacy
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        await waitUntil(timeout: 5) { @MainActor in scroll.scrollerStyle == .overlay }
        let overlayFrame = try #require(
            nativeStableMeasurement(id: anchor.id, host: host, scroll: scroll),
            "The original semantic anchor must have a native measurement after chrome reassertion")
        #expect(abs(overlayFrame.minY - scroll.documentVisibleRect.minY - anchor.relativeOffset) < 4,
                Comment(rawValue: "overlay offset=\(scroll.documentVisibleRect.minY) frame=\(overlayFrame) anchor=\(anchor)"))

        // when — width reflow and prepend overlap immediately through the existing observer path.
        window.setContentSize(CGSize(width: 340, height: 450))
        host.rootView = feed(rows(prepending: true), state: state)
        await waitUntil(timeout: 5) { @MainActor in
            state.viewportPositioned && abs(scroll.contentView.bounds.width - 340) < 1
        }
        await waitUntil(timeout: 5) { @MainActor in
            host.layoutSubtreeIfNeeded()
            return state.viewportPositioned && state.anchor?.id == "tool-older" && !state.followLive.isFollowing
        }

        // then — the scrollbar presentation change did not replace the feed, consume a page, or
        // turn a paused reader back into live-follow.
        #expect(scroll.scrollerStyle == .overlay)
        // The prepend helper groups these rows under the new leading group ID. The retained
        // semantic position therefore migrates from tool-first to tool-older while its native
        // frame and relative offset remain unchanged.
        #expect(state.anchor?.id == "tool-older")
        #expect(!state.followLive.isFollowing)
        #expect(state.scrollOffset.isFinite)
        #expect(abs(offsetBeforeChrome - targetOffset) < 2)
        let replacementRows = rows(prepending: true)
        let replacementGroup = try #require(
            replacementRows.compactMap { row -> ToolGroup? in
                guard case .toolGroup(let group) = row else { return nil }
                return group
            }
.first { $0.id == state.anchor?.id },
            "The migrated semantic anchor must identify the replacement tool group")
        #expect(Set(replacementGroup.members.map(\.id)).isSuperset(of: originalMemberIDs),
                "The replacement semantic group must retain every original member")
        #expect(!Set(replacementRows.map(\.id)).contains(anchor.id),
                "The old semantic anchor identity must be replaced after prepend")
        let replacementFrame = try #require(
            nativeStableMeasurement(id: "tool-older", host: host, scroll: scroll),
            "The migrated semantic anchor must have a native measurement after prepend")
        #expect(abs(replacementFrame.minY - scroll.documentVisibleRect.minY - anchor.relativeOffset) < 4,
                Comment(rawValue: "final offset=\(scroll.documentVisibleRect.minY) frame=\(replacementFrame) anchor=\(anchor)"))
    }

    @Test func givenLiveBottomActivityFeed_whenLegacyChromeIsReasserted_thenBottomFollowRemainsLive() async throws {
        // given — live-follow is intentionally retained at the bottom of a real overflowing feed.
        _ = NSApplication.shared
        let state = ParallelColumnUIState()
        let host = NSHostingView(rootView: feed(rows(prepending: false), state: state))
        let window = activityMountedTestWindow(host, style: [.titled, .resizable])
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 5) { @MainActor in state.viewportPositioned }
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first { $0.hasVerticalScroller })
        let document = try #require(scroll.documentView)
        // Native AppKit scrolling uses the clip view's legal origin, not the document's maxY
        // directly. Scrolling to document.maxY can leave the viewport short of the true bottom.
        let requestedBottom = document.bounds.maxY - scroll.contentView.bounds.height
        let legalBottom = scroll.contentView
.constrainBoundsRect(
            CGRect(origin: CGPoint(x: scroll.contentView.bounds.minX, y: requestedBottom),
                   size: scroll.contentView.bounds.size)
        )
.origin
        scroll.contentView.scroll(to: legalBottom)
        scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil(timeout: 5) { @MainActor in
            state.followLive.isFollowing
                && scroll.documentVisibleRect.maxY >= document.bounds.maxY - 2
        }
        let visibleBottomBeforeChrome = scroll.documentVisibleRect.maxY
        let bottomGapBeforeChrome = document.bounds.maxY - visibleBottomBeforeChrome
        #expect(abs(bottomGapBeforeChrome) < 2)

        // when
        scroll.scrollerStyle = .legacy
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        await waitUntil(timeout: 5) { @MainActor in
            scroll.scrollerStyle == .overlay
                && scroll.documentVisibleRect.maxY >= document.bounds.maxY - 2
        }

        // then — chrome reassertion does not turn live-follow into a paused reading state.
        #expect(state.followLive.isFollowing)
        #expect(scroll.scrollerStyle == .overlay)
        let currentDocument = try #require(scroll.documentView)
        let visibleBottomAfterChrome = scroll.documentVisibleRect.maxY
        let bottomGapAfterChrome = currentDocument.bounds.maxY - visibleBottomAfterChrome
        // Lazy content may reflow and realize rows while chrome changes, so absolute document
        // coordinates are not stable. The native viewport must still be at the current bottom.
        #expect(abs(bottomGapAfterChrome) < 2)
    }

    @Test func givenPausedReadingAnchor_whenScrollbarChromeTransitions_thenPageCallCountAndRelativeAnchorRemainStable() async throws {
        // given — instrument the real pagination callback so a preserved anchor cannot be
        // mistaken for a feed that simply never asked for another page.
        _ = NSApplication.shared
        let requests = PageRequests()
        let state = ParallelColumnUIState()
        state.followLive.suspend()
        let host = NSHostingView(rootView: feed(rows(prepending: false), state: state,
            history: EventHistoryState(hasMore: true), onLoadMore: { requests.total += 1; return true }))
        let window = activityMountedTestWindow(host, style: [.titled, .resizable])
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 5) { @MainActor in state.viewportPositioned }
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first { $0.hasVerticalScroller })

        // when — move to a stable reading position, then transition only the scrollbar chrome.
        var requestedBounds = scroll.contentView.bounds
        requestedBounds.origin.y = 205
        let legalBounds = scroll.contentView.constrainBoundsRect(requestedBounds)
        #expect(abs(legalBounds.minY - 205) < 2)
        scroll.contentView.scroll(to: legalBounds.origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil(timeout: 5) { @MainActor in
            !state.followLive.isFollowing && state.anchor != nil
                && abs(state.scrollOffset - 205) < 2 && abs(scroll.documentVisibleRect.minY - 205) < 2
        }
        let beforeAnchor = try #require(state.anchor)
        let beforeOffset = state.scrollOffset
        let beforeCalls = requests.total
        scroll.scrollerStyle = .legacy
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)

        await waitUntil(timeout: 5) { @MainActor in
            host.layoutSubtreeIfNeeded()
            return scroll.scrollerStyle == .overlay && state.viewportPositioned
                && state.anchor?.id == beforeAnchor.id && !state.followLive.isFollowing
                && abs(state.scrollOffset - beforeOffset) < 3
        }

        // then — chrome-only reassertion preserves reading identity and relative position without
        // issuing an extra page request or silently returning to live-bottom.
        #expect(requests.total == beforeCalls)
        #expect(state.anchor?.id == beforeAnchor.id)
        #expect(abs(state.anchor!.relativeOffset - beforeAnchor.relativeOffset) < 3)
        #expect(abs(state.scrollOffset - beforeOffset) < 3)
        #expect(!state.followLive.isFollowing)
    }

}
