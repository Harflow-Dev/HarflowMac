import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import SwiftUI
import Testing

// MARK: - ActivityFeedReadingGeometryTests

@MainActor extension ActivityFeedReadingGeometryTests {
    func recapture(scroll: NSScrollView, state: ParallelColumnUIState,
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

    func feed(_ rows: [ActivityRow], state: ParallelColumnUIState,
              history: EventHistoryState = EventHistoryState(),
              onLoadMore: (() -> Bool)? = nil) -> some View {
        ActivityFeedView(rows: rows, start: nil, history: history, isLoading: false,
                         horizontalPadding: 24, state: state, onLoadMore: onLoadMore).readingColumn()
    }

    final class PageRequests { var total = 0 }

    func rows(prepending: Bool) -> [ActivityRow] {
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

    func pagedRows(prefix: String, count: Int, sequence: Int) -> [ActivityRow] {
        let timeline = (0 ..< count).map { index in
            ConversationTimelineRow(id: "\(prefix)-\(index)", taskID: "synthetic", timestamp: nil,
                kind: .item(PreviewFixtures.textItem(
                    String(repeating: "History row \(index) varies in height so lazy List realization is observable.\n\n",
                                   count: 1 + (index % 4)), seq: sequence + index)), live: false)
        }
        return ActivityRowsBuilder.build(from: timeline)
    }

    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    func mountedMeasurementFrame(forNativeRow row: Int, host: NSView,
                                 table: NSTableView, scroll: NSScrollView) -> CGRect? {
        guard let document = scroll.documentView else { return nil }
        guard let view = descendants(host)
.compactMap({ $0 as? ActivityFeedNativeCell })
.filter(\.isCoherentNativeMeasurement)
            .first(where: { table.row(for: $0) == row }) else { return nil }
        let frame = view.convert(view.bounds, to: document)
        return frame.intersects(scroll.documentVisibleRect) ? frame : nil
    }

    enum ContinuedWheelDirection: Equatable {
        case up, down

        var deltaY: Int32 { self == .up ? 8 : -8 }
        var offsetDelta: CGFloat { self == .up ? -30 : 30 }
    }

    func exerciseContinuedWheel(direction: ContinuedWheelDirection) async throws {
        _ = NSApplication.shared
        let state = ParallelColumnUIState()
        let requests = PageRequests()
        let current = pagedRows(prefix: "wheel-current", count: 100, sequence: 100)
        let older = pagedRows(prefix: "wheel-older", count: 100, sequence: 0)
        let host = NSHostingView(rootView: feed(current, state: state,
            history: EventHistoryState(hasMore: true), onLoadMore: { requests.total += 1; return true }))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 5) { @MainActor in state.viewportPositioned && state.followLive.isFollowing }
        try #require(state.viewportPositioned && state.followLive.isFollowing)
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first { $0.hasVerticalScroller })
        // Enter the pending-page state through the same native wheel path as the user. The
        // subsequent direction-specific wheel below is the continued input being protected.
        let initialPhase = dispatchScrollWheel(8, phase: .began, in: scroll)
        try #require(initialPhase?.contains(.began) == true,
                     "The initial wheel event must be delivered with began phase; actual phase raw value: \(initialPhase?.rawValue ?? 0)")
        scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.minX, y: 150))
        scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil(timeout: 5) { @MainActor in requests.total > 0 && !state.followLive.isFollowing }
        try #require(requests.total == 1 && !state.followLive.isFollowing)
        let desiredOffset = 150 + direction.offsetDelta

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        let continuedPhase = dispatchScrollWheel(direction.deltaY, phase: .changed, in: scroll)
        try #require(continuedPhase?.contains(.changed) == true,
                     "The continued wheel event must be delivered with changed phase; actual phase raw value: \(continuedPhase?.rawValue ?? 0)")
        scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.minX, y: desiredOffset))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        await waitUntil(timeout: 2) { @MainActor in
            abs(scroll.documentVisibleRect.minY - desiredOffset) < 3
        }
        try #require(abs(scroll.documentVisibleRect.minY - desiredOffset) < 3,
                     "The continued wheel movement must reach the native viewport before publication")
        await waitUntil(timeout: 2) {
            captureMountedAnchor(host: host, scroll: scroll, rowIDs: current.map(\.id)) != nil
        }
        let beforeAnchor = try #require(captureMountedAnchor(host: host, scroll: scroll, rowIDs: current.map(\.id)),
                                        "The latest wheel position must have a mounted semantic anchor")

        host.rootView = feed(older + current, state: state,
            history: EventHistoryState(hasMore: false), onLoadMore: { requests.total += 1; return true })
        await waitUntil(timeout: 5) { @MainActor in
            guard let table = scroll.documentView as? NSTableView else { return false }
            return state.viewportPositioned && !state.followLive.isFollowing && table.numberOfRows >= 200
        }
        let finalAnchor = try #require(captureMountedAnchor(host: host, scroll: scroll,
                                                             rowIDs: (older + current).map(\.id)),
                                       "The latest semantic anchor must remain mounted after publication")
        #expect(finalAnchor.id == beforeAnchor.id,
                "Continued wheel input must win over the stale restoration target")
        #expect(abs(finalAnchor.relativeOffset - beforeAnchor.relativeOffset) < 4,
                "The latest semantic anchor must retain the user's position")
        #expect(requests.total == 1, "The same pending page must not rearm after continued input")
    }

    func dispatchScrollWheel(_ deltaY: Int32, phase: NSEvent.Phase,
                             in scroll: NSScrollView) -> NSEvent.Phase? {
        guard let window = scroll.window else { return nil }
        let point = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: deltaY, wheel2: 0, wheel3: 0) else { return nil }
        // CGScrollPhase uses consecutive values (began=1, changed=2), while NSEvent.Phase
        // reserves a bit for stationary (began=1, changed=4). Passing phase.rawValue directly
        // therefore turns a continued CG wheel into a stationary AppKit event.
        let cgPhase: Int64 = phase.contains(.began) ? 1
            : phase.contains(.changed) ? 2
            : phase.contains(.ended) ? 4
            : phase.contains(.cancelled) ? 8
            : 0
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: cgPhase)
        event.location = window.convertPoint(toScreen: point)
        guard let nsEvent = NSEvent(cgEvent: event) else { return nil }
        // Exercise the production intent classifier; actual movement is measured separately.
        (scroll as? ActivityFeedNativeScrollView)?.owner?.noteUserScrollEvent()
        return nsEvent.phase
    }

    struct MountedFeedAnchor {
        let id: String
        let relativeOffset: CGFloat
    }

    func captureMountedAnchor(host: NSView, scroll: NSScrollView,
                              rowIDs: [String]) -> MountedFeedAnchor? {
        guard let table = scroll.documentView as? NSTableView,
              let document = scroll.documentView else { return nil }
        let nativeIDs = (table as? ActivityFeedNativeTableView)?.owner?.entries.map(\.id) ?? []
        let visible = descendants(host)
.compactMap { $0 as? ActivityFeedNativeCell }
.filter(\.isCoherentNativeMeasurement)
            .compactMap { view -> (Int, CGRect)? in
                let tableRow = table.row(for: view)
                guard nativeIDs.indices.contains(tableRow), let index = rowIDs.firstIndex(of: nativeIDs[tableRow]) else { return nil }
                guard index >= 0, index < rowIDs.count else { return nil }
                let frame = view.convert(view.bounds, to: document)
                guard frame.width > 0, frame.height > 0,
                      frame.maxY > scroll.documentVisibleRect.minY,
                      frame.minY < scroll.documentVisibleRect.maxY else { return nil }
                return (index, frame)
            }
        guard let candidate = visible.min(by: { lhs, rhs in
            abs(lhs.1.minY - scroll.documentVisibleRect.minY)
                < abs(rhs.1.minY - scroll.documentVisibleRect.minY)
        }) else { return nil }
        return MountedFeedAnchor(id: rowIDs[candidate.0],
                                 relativeOffset: candidate.1.minY - scroll.documentVisibleRect.minY)
    }

    func firstVisibleMeasurementFrame(in host: NSView, scroll: NSScrollView) -> CGRect? {
        guard let document = scroll.documentView else { return nil }
        return descendants(host)
            .compactMap { $0 as? ActivityFeedNativeCell }
.filter(\.isCoherentNativeMeasurement)
            .map { $0.convert($0.bounds, to: document) }
            .filter { $0.width > 0 && $0.height > 0 && $0.maxY > scroll.documentVisibleRect.minY
                && $0.minY < scroll.documentVisibleRect.maxY
            }
            .min { $0.minY < $1.minY }
    }

    func measurementFrame(for anchor: ParallelVerticalAnchor, in host: NSView,
                          scroll: NSScrollView) -> CGRect? {
        guard let document = scroll.documentView else { return nil }
        return descendants(host)
            .compactMap { $0 as? ActivityFeedNativeCell }
.filter(\.isCoherentNativeMeasurement)
            .map { $0.convert($0.bounds, to: document) }
            .filter { $0.width > 0 && $0.height > 0 && $0.intersects(scroll.documentVisibleRect) }
            .min { lhs, rhs in
                abs(lhs.minY - scroll.documentVisibleRect.minY - anchor.relativeOffset)
                    < abs(rhs.minY - scroll.documentVisibleRect.minY - anchor.relativeOffset)
            }
    }

    func nativeStableMeasurement(id: String, host: NSView, scroll: NSScrollView) -> CGRect? {
        guard let document = scroll.documentView else { return nil }
        let matches = descendants(host)
.compactMap { $0 as? ActivityFeedNativeCell }
.filter(\.isCoherentNativeMeasurement)
            .filter { $0.stableID == id && $0.enclosingScrollView === scroll }
        guard matches.count == 1, let view = matches.first else { return nil }
        let frame = view.convert(view.bounds, to: document)
        guard frame.width > 0, frame.height > 0, frame.intersects(scroll.documentVisibleRect) else { return nil }
        return frame
    }

    func measurementGeneration(in view: NSView) -> Int {
        descendants(view)
.compactMap { $0 as? ActivityFeedNativeCell }
.filter(\.isCoherentNativeMeasurement)
            .map(\.nativeSnapshotRevision)
.max() ?? -1
    }

    func requireFreshPausedAnchor(host: NSView, scroll: NSScrollView, state: ParallelColumnUIState,
                                  targetOffset: CGFloat) async throws -> ParallelVerticalAnchor {
        var freshPaused = false
        await waitUntil(timeout: 5) { @MainActor in
            guard let anchor = state.anchor,
                  let frame = measurementFrame(for: anchor, in: host, scroll: scroll) else { return false }
            freshPaused = !state.followLive.isFollowing && abs(state.scrollOffset - targetOffset) < 3
                && abs(scroll.documentVisibleRect.minY - targetOffset) < 3
                && abs(frame.minY - scroll.documentVisibleRect.minY - anchor.relativeOffset) < 3
            return freshPaused
        }
        try #require(
            freshPaused,
            Comment(rawValue: "Fresh paused anchor setup failed offset=\(state.scrollOffset) "
                + "native=\(scroll.documentVisibleRect) anchor=\(String(describing: state.anchor))"))
        return try #require(state.anchor)
    }

    func requireOriginalGroup(anchor: ParallelVerticalAnchor) throws -> ToolGroup {
        try #require(
            rows(prepending: false)
.compactMap { row -> ToolGroup? in
                guard case .toolGroup(let group) = row else { return nil }
                return group
            }
.first { $0.id == anchor.id },
            "The paused anchor must identify the original tool group: \(anchor.id)")
    }

}
