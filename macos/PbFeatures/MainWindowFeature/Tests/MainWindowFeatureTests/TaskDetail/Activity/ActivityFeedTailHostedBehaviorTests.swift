import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import SwiftUI
import Testing

/// Hosted behavior checks for the concrete tail surface.  These deliberately drive the mounted
/// committed native presentations, realized geometry and raster output. Button accessibility and
/// wiring are verified in the actual application; callback freshness is an explicit relay test.
@MainActor @Suite(.serialized) struct ActivityFeedTailHostedBehaviorTests {
    @Test func givenMountedChild_whenRootRefreshesWithSameDescriptor_thenMountedActionRelayUsesLatestHandler() async throws {
        let restore = setScrollBars("Always")
        defer { restore() }
        _ = NSApplication.shared
        let state = ParallelColumnUIState()
        let child = try child(id: "child-latest", title: "Child One")
        var selected: [String] = []
        let initial = NSHostingView(rootView: feed(state: state, children: [child], live: "Stable live", onSelect: {
            selected.append("old:\($0)")
        }))
        let window = try open(initial)
        defer { window.contentView = nil; window.close() }
        try await requireText("Child One", in: initial)
        let cell = try #require(activityNativeVisibleTail(initial))
        let relay = try #require(cell.host?.rootView.actions)
        let identity = ObjectIdentifier(relay)
        relay.onSelectChildTask("child-latest")
        try #require(selected == ["old:child-latest"])

        initial.rootView = feed(state: state, children: [child], live: "Stable live", onSelect: {
            selected.append("new:\($0)")
        })
        // The descriptor is unchanged, so its existing text cannot signal that SwiftUI has
        // delivered the replacement root. Let the scheduled representable update run first.
        try await Task.sleep(for: .milliseconds(50))
        try await requireText("Child One", in: initial)
        let refreshed = try #require(activityNativeVisibleTail(initial)?.host?.rootView.actions)
        try #require(ObjectIdentifier(refreshed) == identity)
        refreshed.onSelectChildTask("child-latest")
        #expect(selected == ["old:child-latest", "new:child-latest"])
    }

    @Test func givenMountedTail_whenPresentationHidesAndReturns_thenRetainedViewportAndNativeIdentityRemainStable() async throws {
        let restore = setScrollBars("Always")
        defer { restore() }
        _ = NSApplication.shared
        let state = ParallelColumnUIState()
        let child = try child(id: "child-retained", title: "Retained Child")
        let host = NSHostingView(rootView: feed(state: state, children: [child], live: "Initial live", onSelect: nil))
        let window = try open(host)
        defer { window.contentView = nil; window.close() }
        try await requireText("Initial live", in: host)
        let scroll = try #require(scrollView(in: host))
        let identity = ObjectIdentifier(scroll)
        let following = state.followLive.isFollowing
        let anchor = state.anchor

        host.rootView = feed(state: state, children: [], live: nil, presentation: .absent, onSelect: nil)
        await waitUntil(timeout: 2) { !committedTailText(in: host).contains("Initial live") }
        try #require(!committedTailText(in: host).contains("Initial live"))

        host.rootView = feed(state: state, children: [child], live: "Returned live", onSelect: nil)
        try await requireText("Returned live", in: host)
        let rediscovered = try #require(scrollView(in: host))
        #expect(ObjectIdentifier(rediscovered) == identity)
        #expect(state.followLive.isFollowing == following)
        #expect(state.anchor?.id == anchor?.id)
    }

    @Test func givenTailOnlyFeed_whenMounted_thenNativeRowsContainTailAndSentinelWithExpectedSpacing() async throws {
        let restore = setScrollBars("Always")
        defer { restore() }
        _ = NSApplication.shared
        let state = ParallelColumnUIState()
        let host = NSHostingView(rootView: feed(state: state, children: [], live: "Tail only", rows: []))
        let window = try open(host)
        defer { window.contentView = nil; window.close() }
        try await requireText("Tail only", in: host)
        let scroll = try #require(scrollView(in: host))
        let table = try #require(descendants(scroll.documentView ?? NSView()).compactMap { $0 as? NSTableView }.first)
        var ready = false
        await waitUntil(timeout: 2) {
            ready = table.numberOfRows == 2
            return ready
        }
        try #require(ready, "Tail-only list must expose exactly tail plus sentinel: \(table.numberOfRows)")
        let tail = table.rect(ofRow: 0)
        let sentinel = table.rect(ofRow: 1)
        // The native root includes the original 12-point placement padding and the rendered
        // 15-point live line. Real raster evidence excludes a merely nonzero placeholder slot.
        try #require(activityNativeVisibleTailHasRenderedContent(host))
        let realized = try #require(activityNativeVisibleTail(host))
        #expect(abs(try #require(realized.host).fittingSize.height - tail.height) < 4)
        // The sentinel has no accessible content. Its native 33 pt row is 20 pt top spacing,
        // a 1 pt clear marker, and 12 pt bottom spacing.
        #expect(abs(tail.height - 27) < 4)
        #expect(abs(sentinel.height - 33) < 4)
    }

    @Test func givenTailUpdatesUnderBothScrollbarPreferences_whenMounted_thenLatestCommittedPresentationHasVisibleNativeRendering() async throws {
        for preference in ["Always", "WhenScrolling"] {
            let restore = setScrollBars(preference)
            defer { restore() }
            _ = NSApplication.shared
            let state = ParallelColumnUIState()
            let host = NSHostingView(rootView: feed(state: state, children: [], live: "Rapid 0", rows: []))
            let window = try open(host)
            defer { window.contentView = nil; window.close() }
            for index in 1 ... 3 {
                host.rootView = feed(state: state, children: [], live: "Rapid \(index)",
                                     pending: "Pending \(index)", rows: [])
                try await requireText("Rapid \(index)", in: host)
                try await requireText("Pending \(index)", in: host)
            }
            let scroll = try #require(scrollView(in: host))
            #expect(scroll.scrollerStyle == .overlay)
            #expect(UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["AppleShowScrollBars"] as? String == preference)
        }
    }

    @Test func givenMountedTail_whenHostDetachesAndReattaches_thenStateAndLatestContentSurviveLifecycle() async throws {
        let restore = setScrollBars("Always")
        defer { restore() }
        let state = ParallelColumnUIState()
        let values = rows(count: 32)
        let host = NSHostingView(rootView: feed(state: state, children: [], live: "Before detach", rows: values, onSelect: nil))
        let window = try open(host)
        defer { window.contentView = nil; window.close() }
        try await requireText("Before detach", in: host)
        let scroll = try #require(scrollView(in: host))
        let bottom = try await requireMountedBottom(scroll: scroll, state: state)

        let expectedOffset = max(0, bottom - 40)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: expectedOffset))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        var paused = false
        await waitUntil(timeout: 1) {
            paused = !state.followLive.isFollowing && state.anchor != nil
                && abs(state.scrollOffset - expectedOffset) < 4
            return paused
        }
        try #require(paused, Comment(rawValue: lifecycleMetadata(host: host, state: state)))
        // Pausing changes first-appearance fade inputs. Commit those inputs before recording
        // the lifecycle baseline; their normal revision is not a detach/reattach invalidation.
        await waitUntil(timeout: 3) {
            guard let owner = (scroll.documentView as? ActivityFeedNativeTableView)?.owner else { return false }
            return owner.entries.allSatisfy { entry in
                if case .row(let row) = entry { return !row.fade }
                return true
            }
        }
        let owner = try #require((scroll.documentView as? ActivityFeedNativeTableView)?.owner)
        try #require(owner.entries.allSatisfy { entry in
            if case .row(let row) = entry { return !row.fade }
            return true
        })
        let anchor = try #require(state.anchor)
        let beforeMeasurement = try #require(mountedAnchorMeasurement(id: anchor.id, host: host, scroll: scroll),
                                             "The paused semantic row must have a native measurement")
        let generation = measurementGeneration(in: host)
        let scrollIdentity = ObjectIdentifier(scroll)

        window.contentView = nil
        try await Task.sleep(for: .milliseconds(50))
        window.contentView = host
        window.orderFront(nil)
        host.rootView = feed(state: state, children: [], live: "After reattach", rows: values, onSelect: nil)
        await Task.yield()
        let rediscovered = try #require(scrollView(in: host))
        #expect(ObjectIdentifier(rediscovered) == scrollIdentity)
        #expect(!state.followLive.isFollowing)
        #expect(state.anchor?.id == anchor.id)
        #expect(measurementGeneration(in: host) == generation)
        let afterMeasurement = try #require(
            mountedAnchorMeasurement(id: anchor.id, host: host, scroll: rediscovered),
            "The paused semantic row must remain measured after reattach")
        #expect(abs(afterMeasurement.measurementRelativeOffset - beforeMeasurement.measurementRelativeOffset) < 4)
        #expect(abs(afterMeasurement.nativeRowRelativeOffset - beforeMeasurement.nativeRowRelativeOffset) < 4)
        activityNativeRevealBottom(rediscovered)
        try await requireText("After reattach", in: host)
    }

    @Test func givenMountedTail_whenStripGrowsAndShrinks_thenMountedContentTracksEachSemanticUpdate() async throws {
        let restore = setScrollBars("Always")
        defer { restore() }
        let state = ParallelColumnUIState()
        let first = try child(id: "strip-one", title: "Strip One")
        let second = try child(id: "strip-two", title: "Strip Two")
        let host = NSHostingView(rootView: feed(state: state, children: [first], live: "Strip live", onSelect: nil))
        let window = try open(host)
        defer { window.contentView = nil; window.close() }
        try await requireText("Strip One", in: host)
        host.rootView = feed(state: state, children: [first, second], live: "Strip live 2", onSelect: nil)
        try await requireText("Strip Two", in: host)
        try await requireText("Strip live 2", in: host)
        host.rootView = feed(state: state, children: [second], live: "Strip live 3", onSelect: nil)
        try await requireText("Strip live 3", in: host)
        await waitUntil(timeout: 2) { !activityNativeCommittedTailStrings(host).contains("Strip One") }
        #expect(!activityNativeCommittedTailStrings(host).contains("Strip One"))
    }

    private func requireMountedBottom(scroll: NSScrollView, state: ParallelColumnUIState) async throws -> CGFloat {
        var bottom = CGFloat.zero
        var mountedAtBottom = false
        await waitUntil(timeout: 3) {
            bottom = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
            mountedAtBottom = state.viewportPositioned && abs(scroll.documentVisibleRect.minY - bottom) < 3
            return mountedAtBottom
        }
        try #require(mountedAtBottom)

        return bottom
    }

    private func feed(state: ParallelColumnUIState, children: [TaskDetailTimelineChild], live: String?,
                      pending: String? = nil, rows: [ActivityRow] = [],
                      presentation: ActivityFeedTailPresentation? = nil,
                      onSelect: ((String) -> Void)? = nil) -> some View {
        let semanticPending = pending.map { [PendingMessage(id: "pending", text: $0)] }
            ?? (children.isEmpty && live != nil ? [PendingMessage(id: "semantic", text: "Semantic pending") ] : [])
        let tailValue = ActivityFeedTail(
            liveStep: live.flatMap { _ in LiveStep(rows: [], isRunning: true) },
            pendingMessages: semanticPending, children: children)
        let resolved: ActivityFeedTailPresentation = presentation ?? .standard(.init(
            subTaskStrip: children.isEmpty ? nil : .init(children: children, start: nil),
            pendingMessages: pending.map { [PendingMessage(id: "pending", text: $0)] } ?? [],
            liveStep: live.map { .init(text: $0, indicator: .threeDots) }))
        return ActivityFeedView(rows: rows, start: nil, history: EventHistoryState(), isLoading: false,
                                tailValue: tailValue, state: state, onLoadMore: nil,
                                tailPresentation: resolved, onSelectChildTask: onSelect)
            .frame(width: 420, height: 450)
    }

    private func child(id: String, title: String) throws -> TaskDetailTimelineChild {
        let task = try #require(TaskInfo(.object([
            "task_id": .string(id), "backend": .string("codex"), "status": .string("running"),
            "freedom": .string("read_only"), "started_at": .string("2026-01-01T00:00:00Z")
        ])))
        return TaskDetailTimelineChild(task: task, title: title)
    }

    private func rows(count: Int) -> [ActivityRow] {
        (0 ..< count).map { index in
            .single(ConversationTimelineRow(
                id: "behavior-row-\(index)", taskID: "behavior-task", timestamp: nil,
                kind: .item(PreviewFixtures.textItem(
                    String(repeating: "Behavior row \(index) keeps the viewport populated. ", count: 8),
                    seq: index)), live: false))
        }
    }

    private func lifecycleMetadata(host: NSView, state: ParallelColumnUIState) -> String {
        "follow=\(state.followLive.isFollowing) offset=\(state.scrollOffset) anchor=\(String(describing: state.anchor)) text=\(committedTailText(in: host))"
    }

    private func open(_ host: NSView) throws -> NSWindow {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true,
            forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return window
    }

    private func requireText(_ text: String, in host: NSView) async throws {
        var found = false
        await waitUntil(timeout: 3) {
            found = committedTailText(in: host).contains(text) && activityNativeTailPrerequisite(host)
            return found
        }
        try #require(found, Comment(rawValue:
            "Expected committed native tail presentation and rendered visible geometry: \(text); "
                + "all=\(committedTailText(in: host)); "
                + "views=\(descendants(host).map { String(describing: type(of: $0)) })"))
    }

    private func committedTailText(in host: NSView) -> String {
        activityNativeCommittedTailStrings(host).sorted().joined(separator: "\n")
    }

    private func scrollView(in host: NSView) -> NSScrollView? {
        descendants(host).compactMap { $0 as? NSScrollView }.first { $0.hasVerticalScroller }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

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
            .filter { $0.stableID == id && $0.enclosingScrollView === scroll }
        guard matches.count == 1, let view = matches.first else { return nil }
        let row = table.row(for: view)
        guard row >= 0 else { return nil }
        let measurementFrame = view.convert(view.bounds, to: document)
        let nativeRowFrame = table.rect(ofRow: row)
        guard measurementFrame.width > 0, measurementFrame.height > 0,
              measurementFrame.intersects(scroll.documentVisibleRect), nativeRowFrame.height > 0 else { return nil }
        return MountedAnchorMeasurement(
            measurementRelativeOffset: measurementFrame.minY - scroll.documentVisibleRect.minY,
            nativeRowRelativeOffset: nativeRowFrame.minY - scroll.documentVisibleRect.minY)
    }

    private func measurementGeneration(in host: NSView) -> Int {
        descendants(host)
.compactMap { $0 as? ActivityFeedNativeCell }
.filter(\.isCoherentNativeMeasurement)
            .map(\.nativeSnapshotRevision)
.max() ?? -1
    }

    private func setScrollBars(_ value: String) -> () -> Void {
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var scoped = previous
        scoped["AppleShowScrollBars"] = value
        defaults.setVolatileDomain(scoped, forName: UserDefaults.argumentDomain)
        return { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
    }
}
