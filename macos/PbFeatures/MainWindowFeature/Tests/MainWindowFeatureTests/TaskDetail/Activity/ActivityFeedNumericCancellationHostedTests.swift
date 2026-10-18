import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import SwiftUI
import Testing

/// Real-window regressions for cancelling a numeric restoration while native List geometry is
/// still being delivered.  The assertions use the mounted semantic row and its NSTableView row;
/// state flags alone cannot prove that the visible cell stayed in place.
@MainActor @Suite(.serialized) struct ActivityFeedNumericCancellationHostedTests {
    @Test func givenPausedRowPublication_whenDownIntentAndTailPublicationOverlap_thenCurrentNativeAnchorWins() async throws {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true,
            forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let state = ParallelColumnUIState()
        let rows = activityRows(prefix: "numeric-race", count: 36, revision: 0)
        let host = NSHostingView(rootView: feed(rows: rows, state: state, live: "before", pending: "pending-before"))
        let window = try open(host)
        defer { window.contentView = nil; window.close() }
        try await requireText("before", in: host)
        let scroll = try #require(scrollView(in: host))
        try await waitUntil(timeout: 5) {
            state.viewportPositioned && state.followLive.isFollowing
                && abs(scroll.documentVisibleRect.maxY - (scroll.documentView?.bounds.maxY ?? 0)) < 3
        }

        // Establish a real paused reading anchor, then start the width-driven numeric restore.
        let bottom = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
        let pausedOffset = max(0, bottom - 300)
        activityNativeTestScroll(scroll, to: pausedOffset)
        try await waitUntil(timeout: 5) {
            !state.followLive.isFollowing && state.anchor != nil
                && abs(scroll.documentVisibleRect.minY - pausedOffset) < 3
        }
        let oldAnchor = try #require(state.anchor)
        try #require(mountedAnchor(id: oldAnchor.id, host: host, scroll: scroll) != nil)

        // Same-ID row publication opens the providerless restoration path without changing the
        // native scroll identity or relying on a window resize.
        host.rootView = feed(rows: activityRows(prefix: "numeric-race", count: 36, revision: 1),
                             state: state, live: "before-row-publication", pending: "pending-row-publication")
        await Task.yield()

        // This downward gesture is the user's cancellation. It must synchronously replace the
        // old numeric target with the native position before the tail publication is processed.
        let current = scroll.documentVisibleRect.minY
        let gestureOffset = current + 28
        try sendDownArrow(to: scroll)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: gestureOffset))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        let gestureAnchor = try #require(state.anchor)
        let gestureActualOffset = scroll.documentVisibleRect.minY
        try #require(abs(gestureActualOffset - gestureOffset) < 4,
                     Comment(rawValue: metadata(host: host, state: state)))
        await waitUntil(timeout: 2) {
            mountedAnchor(id: gestureAnchor.id, host: host, scroll: scroll) != nil
        }
        let before = try #require(mountedAnchor(id: gestureAnchor.id, host: host, scroll: scroll),
                                   Comment(rawValue: metadata(host: host, state: state)))

        host.rootView = feed(rows: activityRows(prefix: "numeric-race", count: 36, revision: 2), state: state,
                             live: "after", pending: "pending-after")
        try await requireText("after", in: host)
        await waitUntil(timeout: 5) {
            state.viewportPositioned && !state.followLive.isFollowing
                && abs(scroll.documentVisibleRect.minY - gestureActualOffset) < 4
        }
        let after = try #require(mountedAnchor(id: gestureAnchor.id, host: host, scroll: scroll))
        #expect(state.anchor?.id == gestureAnchor.id)
        #expect(abs(after.measurementRelativeOffset - before.measurementRelativeOffset) < 4)
        #expect(abs(after.nativeRowRelativeOffset - before.nativeRowRelativeOffset) < 4)
    }

    @Test func givenCancelledOlderPageRestore_whenPublicationPrecedesPageCompletion_thenFreshRowsKeepCurrentAnchor() async throws {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true,
            forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let state = ParallelColumnUIState()
        let requests = PageRequests()
        let current = activityRows(prefix: "page-current", count: 100, revision: 0)
        let older = activityRows(prefix: "page-older", count: 100, revision: 0)
        let host = NSHostingView(rootView: feed(rows: current, state: state,
            history: EventHistoryState(hasMore: true), live: "page-before", pending: "page-pending",
            onLoadMore: { requests.total += 1; return true }))
        let window = try open(host)
        defer { window.contentView = nil; window.close() }
        try await requireText("page-before", in: host)
        let scroll = try #require(scrollView(in: host))
        try await waitUntil(timeout: 5) { state.viewportPositioned && state.followLive.isFollowing }

        state.followLive.suspend()
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 150))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await waitUntil(timeout: 5) {
            requests.total > 0 && !state.followLive.isFollowing && state.anchor != nil
        }
        try #require(requests.total == 1, Comment(rawValue: metadata(host: host, state: state)))

        // Cancel the page-backed numeric restoration with a real downward native movement. The
        // anchor must be captured from the current mounted row before either publication below.
        let cancelledOffset = scroll.documentVisibleRect.minY + 28
        try sendDownArrow(to: scroll)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: cancelledOffset))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await waitUntil(timeout: 2) {
            !state.followLive.isFollowing && abs(scroll.documentVisibleRect.minY - cancelledOffset) < 4
        }
        let cancelledAnchor = try #require(state.anchor)
        try #require(mountedAnchor(id: cancelledAnchor.id, host: host, scroll: scroll) != nil)

        // A live tail publication can arrive before the page callback. It must use the coherent
        // post-cancellation native anchor and leave the page lease pending.
        host.rootView = feed(rows: current, state: state,
            history: EventHistoryState(hasMore: true), live: "page-published", pending: "page-published-pending",
            onLoadMore: { requests.total += 1; return true })
        try await requireText("page-published", in: host)
        try #require(!state.followLive.isFollowing)
        let publishedMeasurement = try #require(
            mountedAnchor(id: cancelledAnchor.id, host: host, scroll: scroll))

        // Complete the older page only after publication. The current anchor must remain the
        // same semantic cell, measured against the new NSTableView rows, without rearming the
        // cancelled numeric target.
        host.rootView = feed(rows: older + current, state: state,
            history: EventHistoryState(hasMore: false), live: "page-complete", pending: "page-complete-pending",
            onLoadMore: { requests.total += 1; return true })
        try await requireText("page-complete", in: host)
        try await waitUntil(timeout: 5) {
            state.viewportPositioned && !state.followLive.isFollowing
                && state.anchor?.id == cancelledAnchor.id
                && mountedAnchor(id: cancelledAnchor.id, host: host, scroll: scroll) != nil
        }
        let finalAnchor = try #require(state.anchor)
        let finalMeasurement = try #require(mountedAnchor(id: finalAnchor.id, host: host, scroll: scroll))
        #expect(finalAnchor.id == cancelledAnchor.id)
        #expect(abs(finalMeasurement.measurementRelativeOffset - publishedMeasurement.measurementRelativeOffset) < 4)
        #expect(abs(finalMeasurement.nativeRowRelativeOffset - publishedMeasurement.nativeRowRelativeOffset) < 4)
        #expect(requests.total == 1)
    }

    @Test func givenPausedCompletedRestoration_whenEndNavigationReachesBottom_thenLiveFollowingRemainsArmed() async throws {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true,
            forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let state = ParallelColumnUIState()
        let rows = activityRows(prefix: "end-bottom", count: 80, revision: 0)
        let host = NSHostingView(rootView: feed(rows: rows, state: state, live: "end-before", pending: "end-pending"))
        let window = try open(host)
        defer { window.contentView = nil; window.close() }
        try await requireText("end-before", in: host)
        let scroll = try #require(scrollView(in: host))
        try await waitUntil(timeout: 5) { state.viewportPositioned && state.followLive.isFollowing }
        let bottom = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
        let pausedOffset = max(0, bottom - 80)
        activityNativeTestScroll(scroll, to: pausedOffset)
        try await waitUntil(timeout: 3) {
            !state.followLive.isFollowing && abs(scroll.documentVisibleRect.minY - pausedOffset) < 4
        }
        host.rootView = feed(rows: activityRows(prefix: "end-bottom", count: 80, revision: 1),
            state: state, live: "end-published", pending: "end-published-pending")
        try await requireText("end-published", in: host)
        try #require(state.viewportPositioned && !state.followLive.isFollowing
            && abs(scroll.documentVisibleRect.minY - pausedOffset) < 4,
                     "The completed same-ID restoration must leave the feed paused at its current native position")
        try sendEndArrow(to: scroll)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await waitUntil(timeout: 3) {
            state.followLive.isFollowing
                && abs(scroll.documentVisibleRect.maxY - (scroll.documentView?.bounds.maxY ?? 0)) < 4
        }
        #expect(state.followLive.isFollowing)
        #expect(abs(scroll.documentVisibleRect.maxY - (scroll.documentView?.bounds.maxY ?? 0)) < 4)
    }

    @Test func givenRefusedOlderPageLoad_whenRowsRefresh_thenPausedNativePositionDoesNotReapplyStaleTarget() async throws {
        _ = NSApplication.shared
        let state = ParallelColumnUIState()
        let requests = PageRequests()
        let rows = activityRows(prefix: "refused-load", count: 100, revision: 0)
        let host = NSHostingView(rootView: feed(rows: rows, state: state,
            history: EventHistoryState(hasMore: true), live: "refused-before", pending: "refused-pending",
            onLoadMore: { requests.total += 1; return false }))
        let window = try open(host)
        defer { window.contentView = nil; window.close() }
        try await requireText("refused-before", in: host)
        let scroll = try #require(scrollView(in: host))
        try await waitUntil(timeout: 5) { state.viewportPositioned && state.followLive.isFollowing }
        state.followLive.suspend()
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 150))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await waitUntil(timeout: 5) {
            requests.total == 1 && !state.followLive.isFollowing && state.anchor != nil
        }
        let settledOffset = scroll.documentVisibleRect.minY
        host.rootView = feed(rows: activityRows(prefix: "refused-load", count: 100, revision: 1),
            state: state, history: EventHistoryState(hasMore: true), live: "refused-refresh",
            pending: "refused-refresh-pending", onLoadMore: { requests.total += 1; return false })
        try await requireText("refused-refresh", in: host)
        try await waitUntil(timeout: 3) {
            state.viewportPositioned && !state.followLive.isFollowing
                && abs(scroll.documentVisibleRect.minY - settledOffset) < 4
        }
        #expect(requests.total == 1)
        #expect(!state.followLive.isFollowing)
        #expect(abs(scroll.documentVisibleRect.minY - settledOffset) < 4)
    }

    @Test func givenPendingCancellationCapture_whenNativeDocumentIsMissingAtRetainedBoundary_thenPagingWaitsForCoherentRows() async throws {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true,
            forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let state = ParallelColumnUIState()
        let requests = PageRequests()
        let current = incoherentRows(prefix: "incoherent-current", count: 100, revision: 0)
        let host = NSHostingView(rootView: feed(rows: current, state: state,
            history: EventHistoryState(hasMore: true), live: "incoherent-before", pending: "incoherent-pending",
            onLoadMore: { requests.total += 1; return true }))
        let window = try open(host)
        defer { window.contentView = nil; window.close() }
        try await requireText("incoherent-before", in: host)
        let scroll = try #require(scrollView(in: host))
        try await waitUntil(timeout: 5) { state.viewportPositioned && state.followLive.isFollowing }

        let retainedID = try #require(current.dropFirst(20).first?.id)
        state.retainedFirstID = retainedID
        state.followLive.suspend()
        let bottom = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
        let pausedOffset = max(0, bottom - 300)
        activityNativeTestScroll(scroll, to: pausedOffset)
        try await waitUntil(timeout: 5) {
            !state.followLive.isFollowing && state.anchor != nil
                && abs(scroll.documentVisibleRect.minY - pausedOffset) < 3
        }
        host.rootView = feed(rows: incoherentRows(prefix: "incoherent-current", count: 100, revision: 1),
            state: state, history: EventHistoryState(hasMore: true), live: "incoherent-published",
            pending: "incoherent-published-pending", onLoadMore: { requests.total += 1; return true })
        await Task.yield()
        let table = try #require(scroll.documentView as? NSTableView)
        let originalTableWidth = table.bounds.width
        let olderBoundaryOffset: CGFloat = 150

        // Publish the semantic rows first, then remove the paired native document before the
        // pending-capture actions. This models a real transient where rows exist but their native
        // candidate has not been delivered; the pending cancellation guard must keep the move inert.
        host.rootView = feed(rows: incoherentRows(prefix: "incoherent-current", count: 100, revision: 2),
            state: state, history: EventHistoryState(hasMore: true), live: "incoherent-stale",
            pending: "incoherent-stale-pending", onLoadMore: { requests.total += 1; return true })
        // Temporarily detach the actual document: no native geometry is available for paging.
        let visibleID = try #require(visibleMeasurementID(host: host, scroll: scroll))
        let before = try #require(mountedAnchor(id: visibleID, host: host, scroll: scroll))
        scroll.documentView = nil
        scroll.contentView.scroll(to: CGPoint(x: 0, y: olderBoundaryOffset))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(requests.total == 0,
                "Incoherent native geometry must not open an older-page request")
        #expect(state.retainedFirstID == retainedID,
                "The cancelled capture must retain the existing page boundary")
        // Restore a coherent native marker and allow the pending capture to progress.
        scroll.documentView = table
        table.setFrameSize(CGSize(width: originalTableWidth, height: table.bounds.height))
        await waitUntil(timeout: 5) {
            state.viewportPositioned
                && !state.followLive.isFollowing
                && mountedAnchor(id: visibleID, host: host, scroll: scroll) != nil
        }
        let after = try #require(mountedAnchor(id: visibleID, host: host, scroll: scroll))
        #expect(abs(after.measurementRelativeOffset - before.measurementRelativeOffset) < 4)
        #expect(abs(after.nativeRowRelativeOffset - before.nativeRowRelativeOffset) < 4)
        #expect(requests.total > 0,
                "A later coherent capture must be allowed to resume the retained-boundary request")
        try #require(state.expandedGroups.isEmpty)
        let coherentDisclosure = try await collapsedDisclosure(in: host)
        try #require(press(coherentDisclosure))
        await waitUntil(timeout: 2) { !state.expandedGroups.isEmpty }
        #expect(!state.expandedGroups.isEmpty)
    }

    private func feed(rows: [ActivityRow], state: ParallelColumnUIState,
                      history: EventHistoryState = EventHistoryState(), live: String, pending: String,
                      onLoadMore: (() -> Bool)? = nil, width: CGFloat = 420) -> some View {
        let view = ActivityFeedView(rows: rows, start: nil, history: history, isLoading: false,
                         tailValue: ActivityFeedTail(
                            pendingMessages: [PendingMessage(id: "semantic-pending", text: pending)]),
                         horizontalPadding: 24, state: state, onLoadMore: onLoadMore,
                         tailPresentation: .standard(.init(
                            pendingMessages: [PendingMessage(id: "pending", text: pending)],
                            liveStep: .init(text: live, indicator: .threeDots))))
        return view.frame(width: width, height: 450)
    }

    private func activityRows(prefix: String, count: Int, revision: Int) -> [ActivityRow] {
        (0 ..< count).map { index in
            .single(ConversationTimelineRow(id: "\(prefix)-\(index)", taskID: prefix,
                timestamp: nil, kind: .item(PreviewFixtures.textItem(
                    String(repeating: "A measured activity cell revision \(revision) with enough text to create native List geometry. ", count: 7),
                    seq: index)), live: false))
        }
    }

    private func incoherentRows(prefix: String, count: Int, revision: Int) -> [ActivityRow] {
        let timeline = (0 ..< count).map { index in
            if index % 3 == 2 {
                ConversationTimelineRow(id: "\(prefix)-\(index)", taskID: prefix, timestamp: nil,
                    kind: .item(PreviewFixtures.textItem(
                    String(repeating: "A separator row keeps the grouped disclosure boundaries distinct. ", count: 4),
                    seq: index)), live: false)
            } else {
                ConversationTimelineRow(id: "\(prefix)-\(index)", taskID: prefix, timestamp: nil,
                    kind: .item(PreviewFixtures.toolItem(
                    outputTail: String(repeating: "Tool output revision \(revision) keeps native geometry measurable.\n", count: 3),
                    seq: index, callID: "\(prefix)-group-\(index / 3)")), live: false)
            }
        }
        return ActivityRowsBuilder.build(from: timeline)
    }

    @MainActor private final class PageRequests { var total = 0 }

    private struct MountedAnchor {
        let measurementRelativeOffset: CGFloat
        let nativeRowRelativeOffset: CGFloat
    }

    private func mountedAnchor(id: String, host: NSView, scroll: NSScrollView) -> MountedAnchor? {
        guard let table = scroll.documentView as? NSTableView,
              let view = descendants(host)
                .compactMap({ $0 as? ActivityFeedNativeCell })
.filter(\.isCoherentNativeMeasurement)
                .first(where: { $0.stableID == id && $0.enclosingScrollView === scroll }) else { return nil }
        let row = table.row(for: view)
        guard row >= 0 else { return nil }
        let document = table
        let measurement = view.convert(view.bounds, to: document)
        let native = table.rect(ofRow: row)
        guard measurement.width > 0, measurement.height > 0,
              measurement.intersects(scroll.documentVisibleRect), native.height > 0 else { return nil }
        return MountedAnchor(measurementRelativeOffset: measurement.minY - scroll.documentVisibleRect.minY,
                             nativeRowRelativeOffset: native.minY - scroll.documentVisibleRect.minY)
    }

    private func visibleMeasurementID(host: NSView, scroll: NSScrollView) -> String? {
        guard let table = scroll.documentView as? NSTableView else { return nil }
        return descendants(host)
.compactMap { view -> String? in
            guard let measurement = view as? ActivityFeedNativeCell,
                  measurement.enclosingScrollView === scroll else { return nil }
            let frame = measurement.convert(measurement.bounds, to: table)
            guard frame.width > 0, frame.height > 0,
                  frame.intersects(scroll.documentVisibleRect) else { return nil }
            return measurement.stableID
        }
.first
    }

    private func open(_ host: NSView) throws -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return window
    }

    private func scrollView(in host: NSView) -> NSScrollView? {
        descendants(host).compactMap { $0 as? NSScrollView }.first { $0.hasVerticalScroller }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func sendDownArrow(to scroll: NSScrollView) throws {
        let event = try downArrowEvent(to: scroll)
        let table = try #require(scroll.documentView as? ActivityFeedNativeTableView)
        table.owner?.noteUserScrollEvent()
        #expect(event.charactersIgnoringModifiers == "\u{F701}")
    }

    private func sendEndArrow(to scroll: NSScrollView) throws {
        let window = try #require(scroll.window)
        try #require(window.makeFirstResponder(scroll.contentView))
        let responder = try #require(window.firstResponder as? NSView)
        try #require(responder === scroll || responder.isDescendant(of: scroll))
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{F72B}", charactersIgnoringModifiers: "\u{F72B}",
            isARepeat: false, keyCode: 119))
        try #require(event.window === window)
        let table = try #require(scroll.documentView as? ActivityFeedNativeTableView)
        table.keyDown(with: event)
    }

    private func downArrowEvent(to scroll: NSScrollView) throws -> NSEvent {
        let window = try #require(scroll.window)
        try #require(window.makeFirstResponder(scroll.contentView))
        let responder = try #require(window.firstResponder as? NSView)
        try #require(responder === scroll || responder.isDescendant(of: scroll))
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
            isARepeat: false, keyCode: 125))
        try #require(event.window === window)
        return event
    }

    private func requireText(_ text: String, in host: NSView) async throws {
        var found = false
        await waitUntil(timeout: 5) {
            found = committedTailText(in: host).contains(text) && activityNativeTailPrerequisite(host)
            return found
        }
        try #require(found, Comment(rawValue: "Expected text \(text)"))
    }

    private func committedTailText(in host: NSView) -> String {
        activityNativeCommittedTailStrings(host).sorted().joined(separator: "\n")
    }

    private func accessibilityTree(_ element: NSObject) -> [NSObject] {
        activityNativeAccessibilityTree(element)
    }

    private func collapsedDisclosure(in host: NSView) async throws -> NSObject {
        var button: NSObject?
        await waitUntil(timeout: 3) {
            button = accessibilityTree(host).first { element in
                ["accessibilityValue", "accessibilityLabel", "accessibilityTitle"].contains { key in
                    let selector = NSSelectorFromString(key)
                    return element.responds(to: selector)
                        && (element.value(forKey: key) as? String) == "Collapsed"
                }
            }
            return button != nil
        }
        return try #require(button, "The grouped activity disclosure did not mount")
    }

    private func press(_ element: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard element.responds(to: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = unsafeBitCast(element.method(for: selector), to: Press.self)
        return implementation(element, selector)
    }

    private func metadata(host: NSView, state: ParallelColumnUIState) -> String {
        "offset=\(scrollView(in: host)?.documentVisibleRect.minY as Any) anchor=\(String(describing: state.anchor)) follow=\(state.followLive.isFollowing)"
    }
}
