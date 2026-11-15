import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - ActivityFeedArrivalHostedTests

/// Hosted behaviour of the arrival fade in the real native feed: which rows get the Core Animation
/// fade, when, and with what animation. `ActivityFeedArrivalFadeSpy` counts every add, so "no fade"
/// holds for the whole run and not only while an animation would still be visible.
@MainActor @Suite(.serialized) struct ActivityFeedArrivalHostedTests {
    @MainActor private struct Mounted {
        let state: ParallelColumnUIState
        let host: NSHostingView<AnyView>
        let window: NSWindow
        let table: ActivityFeedNativeTableView
        let scroll: NSScrollView
        let owner: ActivityFeedNativeList.Coordinator

        func close() {
            window.contentView = nil
            window.close()
        }

        func update(_ view: some View) { host.rootView = AnyView(view) }

        func index(of id: String) -> Int? { owner.entries.firstIndex { $0.id == id } }

        func layer(of id: String) -> CALayer? { owner.cells[id]?.host?.layer }
    }

    // MARK: Positive

    @Test func givenFollowingFeed_whenRowAppended_thenItsHostCarriesTheArrivalAnimationRightAfterTheLayoutPass() async throws {
        // given
        let mounted = try await mount(1 ... 40)
        defer { mounted.close() }
        try #require(mounted.state.followLive.isFollowing)
        await waitUntil(timeout: 2) { !hasPlayingFade(mounted) }
        ActivityFeedArrivalFadeSpy.reset()
        // when: the model is applied synchronously, so no run-loop turn can remove the animation
        apply(mounted, rows: rows(1 ... 41))
        // then
        try #require(mounted.index(of: "ti-41") != nil)
        let layer = try #require(mounted.layer(of: "ti-41"), "the new row must be hosted by the end of the layout pass")
        let animation = try #require(layer.animation(forKey: "activityArrival") as? CABasicAnimation)
        #expect(animation.keyPath == "opacity")
        #expect((animation.fromValue as? NSNumber)?.doubleValue == 0)
        #expect((animation.toValue as? NSNumber)?.doubleValue == 1)
        #expect(animation.duration == HfMotion.arrivalDuration)
        #expect(animation.isRemovedOnCompletion)
        #expect(layer.opacity == 1, "the model opacity stays 1")
        let expected = CAMediaTimingFunction(name: .easeOut)
        let actual = try #require(animation.timingFunction)
        for point in 0 ..< 4 {
            var want: [Float] = [0, 0], got: [Float] = [0, 0]
            expected.getControlPoint(at: point, values: &want)
            actual.getControlPoint(at: point, values: &got)
            #expect(want == got, "easeOut control point \(point)")
        }
        #expect(ActivityFeedArrivalFadeSpy.total == 1, "exactly the appended row fades")
        #expect(ActivityFeedArrivalFadeSpy.count(on: layer) == 1)
    }

    @Test func givenFollowingFeed_whenRowAppended_thenPresentationOpacityRisesBelowOneAndEndsAtOne() async throws {
        // given
        let mounted = try await mount(1 ... 40)
        defer { mounted.close() }
        await waitUntil(timeout: 5) { mounted.window.occlusionState.contains(.visible) }
        if !mounted.window.occlusionState.contains(.visible) {
            Issue.record("occlusionState never reported visible (\(mounted.window.occlusionState.rawValue)); presentation opacity is not trustworthy")
        }
        await waitUntil(timeout: 2) { !hasPlayingFade(mounted) }
        // when
        apply(mounted, rows: rows(1 ... 41))
        let layer = try #require(mounted.layer(of: "ti-41"))
        var samples: [Float] = []
        let deadline = Date().addingTimeInterval(HfMotion.arrivalDuration + 0.05)
        while Date() < deadline {
            if let presentation = layer.presentation() { samples.append(presentation.opacity) }
            await waitUntil(timeout: 0.01) { false }
        }
        // then
        print("ARRIVAL_MEASURED presentation_samples=\(samples.count) min=\(samples.min() ?? -1) max=\(samples.max() ?? -1)")
        #expect(!samples.isEmpty, "the layer must have a presentation while fading")
        #expect((samples.min() ?? 1) < 1, "the fade must be observable below full opacity: \(samples)")
        await waitUntil(timeout: 2) { layer.animation(forKey: "activityArrival") == nil }
        #expect(layer.animation(forKey: "activityArrival") == nil, "the animation removes itself on completion")
        #expect(layer.presentation()?.opacity ?? layer.opacity == 1, "the row ends fully visible")
        #expect(layer.opacity == 1)
    }

    @Test func givenFollowingInitialLoad_whenMounted_thenRowsFade() async throws {
        // given
        ActivityFeedArrivalFadeSpy.reset()
        // when
        let mounted = try await mount(1 ... 40)
        defer { mounted.close() }
        // then
        #expect(ActivityFeedArrivalFadeSpy.total >= 1, "visible rows of an initial load while following fade in")
        #expect(ActivityFeedArrivalFadeSpy.total <= mounted.owner.entries.count)
    }

    // MARK: Lifecycle

    @Test func givenArrivedRow_whenScrolledOutAndBackBeforeAnyReconcile_thenNoFadePlaysAgain() async throws {
        // given
        let mounted = try await mount(1 ... 40)
        defer { mounted.close() }
        mounted.update(feed(1 ... 41, state: mounted.state))
        await waitUntil(timeout: 5) { mounted.index(of: "ti-41") != nil }
        await waitUntil(timeout: 2) { !hasPlayingFade(mounted) }
        try #require(mounted.owner.mountedIDs.contains("ti-41"), "the arrived row must have mounted")
        let reconciles = mounted.owner.reconcileCount
        // when: out of view, then back to the bottom
        activityNativeTestScroll(mounted.scroll, to: 0)
        let resumedReconciles = mounted.owner.reconcileCount
        // Rows hosted for the first time on the way back may legitimately fade (initial-load rows
        // that never mounted); the assertion below is scoped to the arrived row.
        ActivityFeedArrivalFadeSpy.reset()
        activityNativeRevealBottom(mounted.scroll)
        await waitUntil(timeout: 3) { mounted.state.followLive.isFollowing }
        await waitUntil(timeout: 3) { mounted.layer(of: "ti-41") != nil }
        // then
        print("ARRIVAL_MEASURED scroll_out_back reconciles_before=\(reconciles) after_out=\(resumedReconciles) after_back=\(mounted.owner.reconcileCount)")
        #expect(mounted.owner.reconcileCount == reconciles, "premise: no reconcile ran while scrolling out and back")
        let layer = try #require(mounted.layer(of: "ti-41"), "the row must be hosted again at the bottom")
        #expect(ActivityFeedArrivalFadeSpy.count(on: layer) == 0, "an arrived row is never faded a second time")
        #expect(layer.animation(forKey: "activityArrival") == nil)
    }

    @Test func givenAllRowsMounted_whenScrolledThroughTheWholeFeedAfterAPausedBuild_thenNothingFades() async throws {
        // given: an initial load whose off-screen rows never mounted, then a build while not following
        let mounted = try await mount(1 ... 40)
        defer { mounted.close() }
        try await pause(mounted, at: 0)
        apply(mounted, rows: rows(1 ... 40))
        try #require(mounted.owner.pendingArrivals.isEmpty, "a build that is not following clears the pending arrivals")
        await waitUntil(timeout: 2) { !hasPlayingFade(mounted) }
        ActivityFeedArrivalFadeSpy.reset()
        // when: walk down the whole feed and back up
        let height = mounted.table.bounds.height
        var offset: CGFloat = 0
        while offset < height {
            activityNativeTestScroll(mounted.scroll, to: offset)
            await waitUntil(timeout: 0.05) { false }
            offset += 150
        }
        activityNativeTestScroll(mounted.scroll, to: 0)
        // then
        #expect(ActivityFeedArrivalFadeSpy.total == 0, "rows that never mounted do not fade when first scrolled into view")
    }

    @Test func givenStreamingRefresh_whenSameEntryChanges_thenNoSecondFadePlays() async throws {
        // given: a row that just arrived, still fading, and an older mounted row
        let mounted = try await mount(1 ... 40)
        defer { mounted.close() }
        await waitUntil(timeout: 2) { !hasPlayingFade(mounted) }
        ActivityFeedArrivalFadeSpy.reset()
        apply(mounted, rows: rows(1 ... 41))
        try #require(ActivityFeedArrivalFadeSpy.total == 1)
        // when: the arrived row and an older row both change text under the same ids
        apply(mounted, rows: rows(1 ... 41, grown: [41, 20, 39]))
        await waitUntil(timeout: 2) { !hasPlayingFade(mounted) }
        // then
        #expect(ActivityFeedArrivalFadeSpy.total == 1, "a refresh of an existing host never replays the fade")
        #expect(ActivityFeedArrivalFadeSpy.count(on: mounted.layer(of: "ti-41")) <= 1)
    }

    @Test func givenRowsAppendedWhileScrolledUp_whenFollowingResumes_thenTheyNeverFade() async throws {
        // given
        let mounted = try await mount(1 ... 40)
        defer { mounted.close() }
        await waitUntil(timeout: 2) { !hasPlayingFade(mounted) }
        let target = try #require(mounted.index(of: "ti-10"))
        try await pause(mounted, at: mounted.table.rect(ofRow: target).minY + 20)
        ActivityFeedArrivalFadeSpy.reset()
        // when: rows arrive while the reader is above the tail
        mounted.update(feed(1 ... 42, state: mounted.state))
        await waitUntil(timeout: 5) { mounted.index(of: "ti-42") != nil }
        try #require(mounted.index(of: "ti-42") != nil)
        // then: nothing is pending and nothing fades
        #expect(mounted.owner.pendingArrivals.isEmpty)
        #expect(ActivityFeedArrivalFadeSpy.total == 0)
        // when: following resumes ("jump to latest") and the new rows come into view
        activityNativeRevealBottom(mounted.scroll)
        await waitUntil(timeout: 3) { mounted.state.followLive.isFollowing }
        await waitUntil(timeout: 2) { mounted.layer(of: "ti-42") != nil }
        await waitUntil(timeout: 1) { false }
        // then
        try #require(mounted.state.followLive.isFollowing)
        #expect(ActivityFeedArrivalFadeSpy.count(on: mounted.layer(of: "ti-41")) == 0)
        #expect(ActivityFeedArrivalFadeSpy.count(on: mounted.layer(of: "ti-42")) == 0)
        #expect(ActivityFeedArrivalFadeSpy.total == 0, "rows added while scrolled up never fade, even once following resumes")
        // and a row appended after following resumed does fade, so the check above is not vacuous
        mounted.update(feed(1 ... 43, state: mounted.state))
        await waitUntil(timeout: 5) { mounted.index(of: "ti-43") != nil }
        await waitUntil(timeout: 2) { ActivityFeedArrivalFadeSpy.total > 0 }
        #expect(ActivityFeedArrivalFadeSpy.total == 1)
    }

    // MARK: Helpers

    /// Whether any realized cell is still playing an arrival fade.
    private func hasPlayingFade(_ mounted: Mounted) -> Bool {
        mounted.owner.cells.values.contains { $0.host?.layer?.animation(forKey: "activityArrival") != nil }
    }

    private func mount(_ range: ClosedRange<Int>) async throws -> Mounted {
        _ = ActivityFeedArrivalFadeSpy.install
        _ = NSApplication.shared
        let state = ParallelColumnUIState()
        let host = NSHostingView(rootView: AnyView(feed(range, state: state)))
        let window = activityMountedTestWindow(host, style: [.titled, .resizable])
        window.orderFront(nil)
        await waitUntil(timeout: 8) { state.viewportPositioned }
        let table = try #require(activityNativeDescendants(host).compactMap { $0 as? ActivityFeedNativeTableView }.first)
        let scroll = try #require(table.enclosingScrollView)
        let owner = try #require(table.owner)
        await waitUntil(timeout: 5) { state.followLive.isFollowing }
        return Mounted(state: state, host: host, window: window, table: table, scroll: scroll, owner: owner)
    }

    private func pause(_ mounted: Mounted, at offset: CGFloat) async throws {
        activityNativeTestScroll(mounted.scroll, to: offset)
        await waitUntil(timeout: 3) { !mounted.state.followLive.isFollowing }
        try #require(!mounted.state.followLive.isFollowing)
    }

    /// Applies a model synchronously through the coordinator, so nothing can run before the check.
    private func apply(_ mounted: Mounted, rows: [ActivityRow]) {
        guard var model = mounted.owner.model else { return }
        model.shownRows = rows
        model.allRowIDs = rows.map(\.id)
        mounted.owner.update(model: model, state: mounted.state, environment: EnvironmentValues(), actions: mounted.owner.actions)
    }

    private func rows(_ range: ClosedRange<Int>, grown: Set<Int> = []) -> [ActivityRow] {
        range.map { index in
            let repeats = grown.contains(index) ? 14 : 4
            return ActivityRow.single(ConversationTimelineRow(
                id: "ti-\(index)", taskID: "arrival-task", timestamp: nil,
                kind: .item(PreviewFixtures.textItem(
                    String(repeating: "Row \(index) wraps across the native reading width. ", count: repeats), seq: index)),
                live: false))
        }
    }

    private func feed(_ range: ClosedRange<Int>, state: ParallelColumnUIState, grown: Set<Int> = []) -> some View {
        ActivityFeedView(rows: rows(range, grown: grown), start: nil, history: EventHistoryState(hasMore: true), isLoading: false,
                         horizontalPadding: 12, state: state, onLoadMore: nil)
            .environment(\.hfReduceMotionOverride, true)
            .environment(\.dynamicTypeSize, .large)
            .frame(width: 420, height: 450)
    }
}
