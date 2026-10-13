import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct ActivityFeedTailHostedTests {
    @Test func givenStandardTail_whenFeedMounts_thenStaticTailAddsRealDocumentGeometry() async throws {
        let restoreScrollPreference = installAlwaysScrollbars()
        defer { restoreScrollPreference() }
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))

        let state = ParallelColumnUIState()
        let host = NSHostingView(rootView: feed(rows: rows(count: 6), state: state, liveText: "Static live step"))
        let window = activityMountedTestWindow(host, style: [.titled])
        let firstMountTrace = NativeMountRecorder()
        let firstMountObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: nil, queue: .main
        ) { [weak host] notification in
            guard let object = notification.object as? NSView, let host else { return }
            let objectID = ObjectIdentifier(object)
            MainActor.assumeIsolated { firstMountTrace.record(objectID: objectID, in: host) }
        }
        window.orderFront(nil)
        defer {
            NotificationCenter.default.removeObserver(firstMountObserver)
            window.contentView = nil
            window.close()
        }

        try await requireInitialTail(host: host, state: state)
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
        try #require(NSScroller.preferredScrollerStyle == .legacy)
        #expect(scroll.scrollerStyle == .overlay)
        #expect((scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height)
        #expect(state.followLive.isFollowing)
        var validSamples: [NativeMountRecorder.Sample] = []
        await waitUntil(timeout: 0.5) {
            validSamples = firstMountTrace.samples.filter { sample in
                sample.documentHeight > sample.viewportHeight && !sample.rowIDs.isEmpty
            }
            return validSamples.contains { sample in
                sample.documentHeight - sample.offset - sample.viewportHeight <= 3
            }
        }
        try #require(!validSamples.isEmpty)
        let first = try #require(validSamples.first { $0.documentHeight - $0.offset - $0.viewportHeight <= 3 })
        #expect(first.documentHeight - first.offset - first.viewportHeight <= 3)
        #expect(first.viewportHeight > 0)
        let offsets = validSamples.map(\.offset)
        let heights = validSamples.map(\.documentHeight)
        let directions = zip(offsets, offsets.dropFirst())
.map { $1 - $0 }
            .filter { abs($0) > 5 }
            .map { $0 > 0 ? 1 : -1 }
        let reversals = zip(directions, directions.dropFirst()).filter { $0 != $1 }.count
        let heightTransitions = zip(heights, heights.dropFirst()).filter { abs($1 - $0) > 1 }.count
        #expect(reversals == 0)
        #expect(heightTransitions < 3)
        let firstIDs = first.rowIDs
        let firstFrames = Dictionary(uniqueKeysWithValues: zip(firstIDs, first.rowFrames))
        #expect(validSamples.dropFirst().allSatisfy { sample in
            firstIDs.allSatisfy { id in
                guard let frame = firstFrames[id], let index = sample.rowIDs.firstIndex(of: id) else { return false }
                return abs(frame.minY - first.offset - (sample.rowFrames[index].minY - sample.offset)) < 3
            }
        })
    }

    @Test func givenStandardTail_whenLiveTextChangesDuringUpwardRead_thenMountedViewportAndAnchorRemainStable() async throws {
        let restoreScrollPreference = installAlwaysScrollbars()
        defer { restoreScrollPreference() }
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))

        let state = ParallelColumnUIState()
        let values = rows(count: 32)
        let host = NSHostingView(rootView: feed(rows: values, state: state, liveText: "Static live step"))
        let window = activityMountedTestWindow(host, style: [.titled, .resizable])
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        try await requireInitialTail(host: host, state: state)
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
        try #require(NSScroller.preferredScrollerStyle == .legacy)
        #expect(scroll.scrollerStyle == .overlay)
        let mountedIdentity = ObjectIdentifier(scroll)

        let bottom = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
        try await requireInitialBottomAligned(scroll: scroll, state: state, bottom: bottom)
        let offsetTrace = OffsetTrace(values: [scroll.documentVisibleRect.minY])
        let boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { _ in
            MainActor.assumeIsolated { offsetTrace.values.append(scroll.documentVisibleRect.minY) }
        }
        defer { NotificationCenter.default.removeObserver(boundsObserver) }
        let gestureStartOffset = scroll.documentVisibleRect.minY
        activityNativeTestScroll(scroll, to: max(0, bottom - 40))
        var paused = false
        let expectedGestureOffset = max(0, bottom - 40)
        await waitUntil(timeout: 0.5) {
            paused = !state.followLive.isFollowing && state.anchor != nil
                && abs(state.scrollOffset - expectedGestureOffset) < 4
            return paused
        }
        try #require(paused, Comment(rawValue: initialMetadata(host: host, state: state)))
        let gestureEndOffset = scroll.documentVisibleRect.minY
        try #require(abs((gestureStartOffset - gestureEndOffset) - 40) < 4)
        try #require(abs(state.scrollOffset - gestureEndOffset) < 4)
        let beforeViewport = scroll.contentView.bounds.size
        let beforeAnchor = try #require(state.anchor)
        try await requireSettledAnchor(state: state, beforeAnchor: beforeAnchor)

        let mutationTraceStart = offsetTrace.values.count
        // Keep the pre-mutation point in the same bounded trace as any native
        // bounds notifications.  A presentation update can legitimately emit
        // no notification when geometry is unchanged, but the trace must still
        // contain observable start and settled samples.
        offsetTrace.values.append(scroll.documentVisibleRect.minY)
        host.rootView = feed(rows: values, state: state, liveText: "Updated live step while reading")
        // Allow the hosted view to finish its presentation-triggered work before
        // taking the terminal sample.  This is deliberately bounded and does
        // not manufacture a movement event when the native bounds stay still.
        try await Task.sleep(for: .milliseconds(500))
        offsetTrace.values.append(scroll.documentVisibleRect.minY)

        try await waitForStableNativeGeometry(scroll)

        let rediscovered = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
        #expect(ObjectIdentifier(rediscovered) == mountedIdentity)
        #expect(scroll.scrollerStyle == .overlay)
        let mutationOffsets = offsetTrace.values.dropFirst(mutationTraceStart)
        #expect(mutationOffsets.map { abs($0 - gestureEndOffset) }.max() ?? .infinity < 4)
        #expect(abs(scroll.documentVisibleRect.minY - gestureEndOffset) < 4)
        #expect(abs(scroll.contentView.bounds.width - beforeViewport.width) < 4)
        #expect(abs(scroll.contentView.bounds.height - beforeViewport.height) < 4)
        #expect(state.anchor?.id == beforeAnchor.id)
        #expect(abs((state.anchor?.relativeOffset ?? .infinity) - beforeAnchor.relativeOffset) < 4)
        #expect(!state.followLive.isFollowing)
        activityNativeRevealBottom(scroll)
        await waitUntil { activityNativeTailPrerequisite(host) && activityNativeCommittedTailStrings(host).contains("Updated live step while reading") }
        try #require(activityNativeTailPrerequisite(host) && activityNativeCommittedTailStrings(host).contains("Updated live step while reading"))
    }

    private func requireInitialBottomAligned(scroll: NSScrollView, state: ParallelColumnUIState,
                                             bottom: CGFloat) async throws {
        var initialBottomAligned = false
        await waitUntil {
            initialBottomAligned = state.viewportPositioned && state.anchor != nil
                && abs(scroll.documentVisibleRect.minY - bottom) < 3
            return initialBottomAligned
        }
        try #require(initialBottomAligned)
    }

    private func requireInitialTail(host: NSView, state: ParallelColumnUIState) async throws {
        var initialTailReady = false
        await waitUntil {
            let text = committedTailStrings(in: host).joined(separator: "\n") + "\n" + nativeFieldStrings(in: host).joined(separator: "\n")
            initialTailReady = activityNativeTailPrerequisite(host) && text.contains("Static live step") && text.contains("Static pending message")
            return initialTailReady
        }
        try #require(initialTailReady, Comment(rawValue: initialMetadata(host: host, state: state)))
    }

    private func requireSettledAnchor(state: ParallelColumnUIState, beforeAnchor: ParallelVerticalAnchor) async throws {
        var settledAnchor = false
        var stableAnchorSamples = 0
        var previousAnchor = beforeAnchor
        await waitUntil {
            let current = state.anchor
            if current == previousAnchor { stableAnchorSamples += 1 } else { stableAnchorSamples = 0 }
            previousAnchor = current ?? previousAnchor
            settledAnchor = current != nil && stableAnchorSamples >= 2
            return settledAnchor
        }
        try #require(settledAnchor)
    }

    private func waitForStableNativeGeometry(_ scroll: NSScrollView) async throws {
        var stableSamples = 0
        var previous = (offset: scroll.documentVisibleRect.minY,
                        height: scroll.documentView?.bounds.height ?? 0)
        var settled = false
        await waitUntil {
            let current = (offset: scroll.documentVisibleRect.minY,
                           height: scroll.documentView?.bounds.height ?? 0)
            if abs(current.offset - previous.offset) < 0.5,
               abs(current.height - previous.height) < 0.5 {
                stableSamples += 1
            } else {
                stableSamples = 0
            }
            previous = current
            settled = stableSamples >= 3
            return settled
        }
        try #require(settled)
    }

    @Test func givenStandardTail_whenReadingUpwardWithoutMutation_thenNativeGesturePreservesPausedAnchor() async throws {
        let restoreScrollPreference = installAlwaysScrollbars()
        defer { restoreScrollPreference() }
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))

        let state = ParallelColumnUIState()
        let host = NSHostingView(rootView: feed(rows: rows(count: 32), state: state, liveText: "Static live step"))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        var initialTailReady = false
        await waitUntil {
            let text = committedTailStrings(in: host).joined(separator: "\n") + "\n" + nativeFieldStrings(in: host).joined(separator: "\n")
            initialTailReady = activityNativeTailPrerequisite(host) && text.contains("Static live step") && state.viewportPositioned
            return initialTailReady
        }
        try #require(initialTailReady, Comment(rawValue: initialMetadata(host: host, state: state)))
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
        let bottom = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
        var settled = false
        await waitUntil {
            settled = state.anchor != nil && abs(scroll.documentVisibleRect.minY - bottom) < 3
            return settled
        }
        try #require(settled)
        let trace = OffsetTrace(values: [scroll.documentVisibleRect.minY])
        let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                               object: scroll.contentView, queue: .main) { _ in
            MainActor.assumeIsolated { trace.values.append(scroll.documentVisibleRect.minY) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let start = scroll.documentVisibleRect.minY
        let traceStart = trace.values.count
        let expectedOffset = max(0, bottom - 40)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: expectedOffset)); scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        var controlSettled = false
        await waitUntil(timeout: 0.5) {
            controlSettled = !state.followLive.isFollowing && state.anchor != nil
                && abs(state.scrollOffset - expectedOffset) < 4
            return controlSettled
        }
        try #require(controlSettled, Comment(rawValue: initialMetadata(host: host, state: state)))
        let end = scroll.documentVisibleRect.minY
        #expect(abs((start - end) - 40) < 4)
        #expect(abs(end - expectedOffset) < 4)
        #expect(abs(state.scrollOffset - end) < 4)
        #expect(trace.values.dropFirst(traceStart).allSatisfy { abs($0 - expectedOffset) < 4 })
        #expect(scroll.scrollerStyle == .overlay)
    }

    private func feed(rows: [ActivityRow], state: ParallelColumnUIState, liveText: String) -> some View {
        ActivityFeedView(rows: rows, start: nil, history: EventHistoryState(), isLoading: false,
                         tailValue: ActivityFeedTail(
                            liveStep: LiveStep(rows: [], isRunning: true),
                            pendingMessages: [PendingMessage(id: "pending", text: "Static pending message")]),
                         horizontalPadding: 24, state: state, onLoadMore: nil,
                         tailPresentation: .standard(.init(
                            pendingMessages: [PendingMessage(id: "pending", text: "Static pending message")],
                            liveStep: .init(text: liveText, indicator: .threeDots))))
            .frame(width: 420, height: 450)
    }

    private func rows(count: Int) -> [ActivityRow] {
        (0 ..< count).map { index in
            .single(ConversationTimelineRow(
                id: "tail-row-\(index)", taskID: "tail-task", timestamp: nil,
                kind: .item(PreviewFixtures.textItem(
                    String(repeating: "Activity row \(index) keeps the reading viewport populated. ", count: 8), seq: index)), live: false))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func committedTailStrings(in host: NSView) -> Set<String> {
        activityNativeCommittedTailStrings(host)
    }

    private func nativeFieldStrings(in host: NSView) -> [String] {
        descendants(host).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    private func initialMetadata(host: NSView, state: ParallelColumnUIState) -> String {
        let scroll = descendants(host).compactMap { $0 as? NSScrollView }.first
        let tableRows = scroll.flatMap { descendants($0.documentView ?? NSView()).compactMap { $0 as? NSTableView }.first?.numberOfRows }
        return "committedTail=\(committedTailStrings(in: host).sorted()) native=\(nativeFieldStrings(in: host)) "
            + "positioned=\(state.viewportPositioned) follow=\(state.followLive.isFollowing) anchor=\(String(describing: state.anchor)) "
            + "tableRows=\(String(describing: tableRows)) document=\(String(describing: scroll?.documentView?.bounds)) "
            + "clip=\(String(describing: scroll?.contentView.bounds)) offset=\(String(describing: scroll?.documentVisibleRect.minY))"
    }

    private func installAlwaysScrollbars() -> () -> Void {
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var scoped = previous
        scoped["AppleShowScrollBars"] = "Always"
        defaults.setVolatileDomain(scoped, forName: UserDefaults.argumentDomain)
        return { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
    }

    @MainActor private final class NativeMountRecorder {
        struct Sample {
            let offset: CGFloat
            let documentHeight: CGFloat
            let viewportHeight: CGFloat
            let rowIDs: [String]
            let rowFrames: [CGRect]
        }

        var samples: [Sample] = []

        func record(objectID: ObjectIdentifier, in root: NSView) {
            guard let scroll = descendants(root).compactMap({ $0 as? NSScrollView }).first(where: {
                ObjectIdentifier($0.contentView) == objectID && $0.hasVerticalScroller
            }), let document = scroll.documentView else { return }
            let measured = descendants(document).compactMap { $0 as? ActivityFeedNativeCell }.filter(\.isCoherentNativeMeasurement)
            guard !measured.isEmpty else { return }
            let rows = measured.map { ($0.stableID ?? "", $0.convert($0.bounds, to: document)) }
            samples.append(Sample(offset: scroll.documentVisibleRect.minY, documentHeight: document.bounds.height,
                                  viewportHeight: scroll.contentView.bounds.height,
                                  rowIDs: rows.map(\.0), rowFrames: rows.map(\.1)))
        }

        private func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
    }

    @MainActor private final class OffsetTrace {
        var values: [CGFloat]
        init(values: [CGFloat]) { self.values = values }
    }
}
