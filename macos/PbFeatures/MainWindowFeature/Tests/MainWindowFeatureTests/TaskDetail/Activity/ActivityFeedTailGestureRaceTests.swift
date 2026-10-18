import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct ActivityFeedTailGestureRaceTests {
    @Test func givenPausedUpwardRead_whenMovingDownIntoBottomZone_thenFollowingResumes() async throws {
        let restore = scopedScrollBars("Always")
        defer { restore() }
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let state = ParallelColumnUIState()
        let host = NSHostingView(rootView: feed(rows: activityRows(count: 32), state: state, live: "Direction", pending: "Direction pending"))
        let window = try open(host)
        defer { window.contentView = nil; window.close() }
        try await requireText("Direction", host: host)
        let scroll = try #require(scrollView(in: host))
        var bottom: CGFloat = 0
        var mounted = false
        await waitUntil(timeout: 3) {
            bottom = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
            mounted = state.viewportPositioned && abs(scroll.documentVisibleRect.minY - bottom) < 3
            return mounted
        }
        try #require(mounted)
        let up = max(0, bottom - 20)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: up)); scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        var paused = false
        await waitUntil(timeout: 1) { paused = !state.followLive.isFollowing && abs(state.scrollOffset - up) < 4; return paused }
        try #require(paused, Comment(rawValue: initialMetadata(host: host, state: state)))

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: bottom)); scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        var resumed = false
        await waitUntil(timeout: 1) { resumed = state.followLive.isFollowing && abs(scroll.documentVisibleRect.minY - bottom) < 4; return resumed }
        try #require(resumed, Comment(rawValue: initialMetadata(host: host, state: state)))
    }

    @Test func givenEarlyMount_whenUpGestureAndTailPublicationOverlap_thenReadingPositionRemainsPaused() async throws {
        let restore = scopedScrollBars("Always")
        defer { restore() }
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let state = ParallelColumnUIState()
        let rows = activityRows(count: 32)
        let host = NSHostingView(rootView: feed(rows: rows, state: state, live: "Early before", pending: "Early pending"))
        let window = try open(host)
        defer { window.contentView = nil; window.close() }
        try await requireText("Early before", host: host)
        let scroll = try #require(scrollView(in: host))
        var bottom = CGFloat.zero
        var mounted = false
        await waitUntil(timeout: 3) {
            bottom = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
            mounted = state.viewportPositioned && abs(scroll.documentVisibleRect.minY - bottom) < 3
            return mounted
        }
        try #require(mounted)
        let expected = max(0, bottom - 40)
        let trace = OffsetTrace(values: [scroll.documentVisibleRect.minY])
        let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                               object: scroll.contentView, queue: .main) { _ in
            MainActor.assumeIsolated { trace.values.append(scroll.documentVisibleRect.minY) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: expected)); scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        // The native gesture callback must publish a fresh visible anchor synchronously before
        // the overlapping tail publication is allowed to run; otherwise this test could pass
        // while retaining the old bottom anchor.
        let gestureAnchor = try #require(state.anchor)
        try #require(abs(state.scrollOffset - expected) < 4,
                     Comment(rawValue: initialMetadata(host: host, state: state)))
        let beforeMeasurement = try #require(
            mountedAnchorMeasurement(id: gestureAnchor.id, host: host, scroll: scroll),
            "The upward gesture must have a mounted native row measurement")
        #expect(abs(beforeMeasurement.measurementRelativeOffset - gestureAnchor.relativeOffset) < 4,
                "The gesture anchor must describe the actual measured row before tail publication")
        host.rootView = feed(rows: rows, state: state, live: "Early after", pending: "Early changed")
        try await requireText("Early after", host: host)
        try await Task.sleep(for: .milliseconds(500))
        trace.values.append(scroll.documentVisibleRect.minY)
        #expect(!state.followLive.isFollowing, Comment(rawValue: initialMetadata(host: host, state: state)))
        #expect(state.anchor?.id == gestureAnchor.id)
        #expect(abs((state.anchor?.relativeOffset ?? .infinity) - gestureAnchor.relativeOffset) < 4)
        let afterMeasurement = try #require(
            mountedAnchorMeasurement(id: gestureAnchor.id, host: host, scroll: scroll),
            "The retained gesture row must remain measured after tail reflow")
        #expect(abs(afterMeasurement.measurementRelativeOffset - gestureAnchor.relativeOffset) < 4,
                "The retained row measurement must stay aligned with the gesture anchor")
        #expect(abs(afterMeasurement.nativeRowRelativeOffset - beforeMeasurement.nativeRowRelativeOffset) < 4,
                "The native row must stay aligned across tail reflow")
    }

    @Test func givenPausedRows_whenTailChangesImmediatelyAfterUpGesture_thenNativeOffsetAndAnchorStayAtNewPosition() async throws {
        let restore = scopedScrollBars("Always")
        defer { restore() }
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let state = ParallelColumnUIState()
        let rows = activityRows(count: 32)
        let host = NSHostingView(rootView: feed(rows: rows, state: state, live: "Race before", pending: "Pending before"))
        let window = try open(host)
        defer { window.contentView = nil; window.close() }
        try await requireText("Race before", host: host)
        let scroll = try #require(scrollView(in: host))
        let identity = ObjectIdentifier(scroll)
        try await requireStableOverlayGeometry(scroll)
        var bottom = CGFloat.zero
        var ready = false
        await waitUntil(timeout: 3) {
            bottom = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
            ready = state.viewportPositioned && abs(scroll.documentVisibleRect.minY - bottom) < 3
            return ready
        }
        try #require(ready)

        let expected = max(0, bottom - 40)
        let trace = OffsetTrace(values: [scroll.documentVisibleRect.minY])
        let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                               object: scroll.contentView, queue: .main) { _ in
            MainActor.assumeIsolated { trace.values.append(scroll.documentVisibleRect.minY) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: expected))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        let gestureTraceStart = trace.values.count

        // Publish the tail before waiting for the scheduled anchor capture. This is the race that
        // previously allowed presentation work to restore the old bottom position.
        host.rootView = feed(rows: rows, state: state, live: "Race after", pending: "Pending after")
        try await requireText("Race after", host: host)
        var paused = false
        await waitUntil(timeout: 1) {
            paused = !state.followLive.isFollowing && abs(state.scrollOffset - expected) < 4
            return paused
        }
        try #require(paused, Comment(rawValue: initialMetadata(host: host, state: state)))
        try await Task.sleep(for: .milliseconds(500))
        trace.values.append(scroll.documentVisibleRect.minY)
        try #require(ObjectIdentifier(try #require(scrollView(in: host))) == identity)
        try #require(!trace.values.dropFirst(gestureTraceStart).isEmpty)
        #expect(trace.values.dropFirst(gestureTraceStart).allSatisfy { abs($0 - expected) < 4 }, Comment(rawValue: trace.values.description))
        #expect(abs(scroll.documentVisibleRect.minY - expected) < 4)
        #expect(state.anchor != nil)
    }

    @Test func givenKnownOffscreenAnchor_whenTailChangesBeforeSecondGesture_thenFreshGestureRemainsPaused() async throws {
        let restore = scopedScrollBars("Always")
        defer { restore() }
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let state = ParallelColumnUIState()
        let rows = activityRows(count: 32)
        let host = NSHostingView(rootView: feed(rows: rows, state: state, live: "Anchor before", pending: "Pending before"))
        let window = try open(host)
        defer { window.contentView = nil; window.close() }
        try await requireText("Anchor before", host: host)
        let scroll = try #require(scrollView(in: host))
        var stableGeometrySamples = 0
        var previousGeometry = (height: CGFloat.zero, width: CGFloat.zero, clip: CGFloat.zero)
        var geometryReady = false
        await waitUntil(timeout: 2) {
            let current = (height: scroll.documentView?.bounds.height ?? 0,
                           width: scroll.bounds.width, clip: scroll.contentView.bounds.width)
            if abs(current.height - previousGeometry.height) < 0.5,
               abs(current.width - previousGeometry.width) < 0.5,
               abs(current.clip - previousGeometry.clip) < 0.5 { stableGeometrySamples += 1 } else { stableGeometrySamples = 0 }
            previousGeometry = current
            geometryReady = scroll.scrollerStyle == .overlay && stableGeometrySamples >= 3
            return geometryReady
        }
        try #require(geometryReady, "The mounted overlay geometry must settle before the second gesture")
        var bottom = CGFloat.zero
        var ready = false
        await waitUntil(timeout: 3) {
            bottom = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
            ready = state.viewportPositioned && abs(scroll.documentVisibleRect.minY - bottom) < 3
            return ready
        }
        try #require(ready)
        // Row zero is a real known anchor from this feed, but it is unrealized while mounted at
        // the bottom. The second gesture must therefore win after the tail update before that
        // anchor can be measured again.
        state.anchor = ParallelVerticalAnchor(id: "race-row-0", index: 0, relativeOffset: 18)
        let expected = max(0, bottom - 40)
        host.rootView = feed(rows: rows, state: state, live: "Anchor changed", pending: "Pending changed")
        try await requireText("Anchor changed", host: host)

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: expected))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        let secondExpected = max(0, bottom - 80)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: secondExpected))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        var paused = false
        await waitUntil(timeout: 1) {
            paused = !state.followLive.isFollowing && abs(state.scrollOffset - secondExpected) < 4
            return paused
        }
        try #require(paused, Comment(rawValue: initialMetadata(host: host, state: state)))
        #expect(abs(scroll.documentVisibleRect.minY - secondExpected) < 4)
        #expect(!committedTailText(in: host).isEmpty)
    }

    private func requireStableOverlayGeometry(_ scroll: NSScrollView) async throws {
        var previousGeometry = (height: CGFloat.zero, width: CGFloat.zero, clip: CGFloat.zero)
        var stableGeometrySamples = 0
        var geometryReady = false
        await waitUntil(timeout: 2) {
            let current = (height: scroll.documentView?.bounds.height ?? 0,
                           width: scroll.bounds.width, clip: scroll.contentView.bounds.width)
            if abs(current.height - previousGeometry.height) < 0.5,
               abs(current.width - previousGeometry.width) < 0.5,
               abs(current.clip - previousGeometry.clip) < 0.5 { stableGeometrySamples += 1 } else { stableGeometrySamples = 0 }
            previousGeometry = current
            geometryReady = scroll.scrollerStyle == .overlay && stableGeometrySamples >= 3
            return geometryReady
        }
        try #require(geometryReady, "The mounted overlay geometry must settle before the race gesture")
    }

    private func feed(rows: [ActivityRow], state: ParallelColumnUIState, live: String, pending: String) -> some View {
        ActivityFeedView(rows: rows, start: nil, history: EventHistoryState(), isLoading: false,
                         tailValue: ActivityFeedTail(pendingMessages: [PendingMessage(id: "semantic", text: pending)]),
                         state: state, onLoadMore: nil,
                         tailPresentation: .standard(.init(
                            pendingMessages: [PendingMessage(id: "pending", text: pending)],
                            liveStep: .init(text: live, indicator: .threeDots))))
            .frame(width: 420, height: 450)
    }

    private func activityRows(count: Int) -> [ActivityRow] {
        (0 ..< count).map { index in
            .single(ConversationTimelineRow(id: "race-row-\(index)", taskID: "race-task", timestamp: nil,
                kind: .item(PreviewFixtures.textItem(String(repeating: "Race row \(index) keeps the viewport populated. ", count: 8),
                    seq: index)), live: false))
        }
    }

    private func open(_ host: NSView) throws -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        return window
    }

    private func requireText(_ text: String, host: NSView) async throws {
        var found = false
        await waitUntil(timeout: 3) { found = committedTailText(in: host).contains(text) && activityNativeTailPrerequisite(host); return found }
        try #require(found, Comment(rawValue: initialMetadata(host: host, state: ParallelColumnUIState())))
    }

    private func committedTailText(in host: NSView) -> String {
        activityNativeCommittedTailStrings(host).sorted().joined(separator: "\n")
    }

    private func initialMetadata(host: NSView, state: ParallelColumnUIState) -> String {
        "committedTail=\(committedTailText(in: host)) offset=\(scrollView(in: host)?.documentVisibleRect.minY as Any)"
            + " anchor=\(String(describing: state.anchor)) follow=\(state.followLive.isFollowing)"
    }

    private func scrollView(in host: NSView) -> NSScrollView? {
        descendants(host).compactMap { $0 as? NSScrollView }.first { $0.hasVerticalScroller }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private struct MountedAnchorMeasurement {
        let measurementRelativeOffset: CGFloat
        let nativeRowRelativeOffset: CGFloat
    }

    private func mountedAnchorMeasurement(id: String, host: NSView,
                                          scroll: NSScrollView) -> MountedAnchorMeasurement? {
        guard let table = scroll.documentView as? NSTableView,
              let document = scroll.documentView else { return nil }
        let matches = descendants(host)
.compactMap { $0 as? ActivityFeedNativeCell }
.filter(\.isCoherentNativeMeasurement)
            .filter { $0.entryID == id && $0.enclosingScrollView === scroll }
        guard matches.count == 1, let cell = matches.first else { return nil }
        let targetRow = table.row(for: cell)
        guard targetRow >= 0 else { return nil }
        let mountedFrame = cell.convert(cell.bounds, to: document)
        let nativeRowFrame = table.rect(ofRow: targetRow)
        guard mountedFrame.width > 0, mountedFrame.height > 0,
              mountedFrame.intersects(scroll.documentVisibleRect),
              nativeRowFrame.height > 0 else { return nil }
        return MountedAnchorMeasurement(
            measurementRelativeOffset: mountedFrame.minY - scroll.documentVisibleRect.minY,
            nativeRowRelativeOffset: nativeRowFrame.minY - scroll.documentVisibleRect.minY)
    }

    private func scopedScrollBars(_ value: String) -> () -> Void {
        let defaults = UserDefaults.standard; let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var scoped = previous; scoped["AppleShowScrollBars"] = value; defaults.setVolatileDomain(scoped, forName: UserDefaults.argumentDomain)
        return { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
    }

    @MainActor private final class OffsetTrace { var values: [CGFloat]; init(values: [CGFloat]) { self.values = values } }
}
