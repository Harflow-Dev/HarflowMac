import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct ParallelViewportTests {
    @Test func givenHorizontalAnchor_whenColumnsReorderResizeOrDisappear_thenIdentityAndRelativeOffsetAreRetained() throws {
        // given
        let anchor = try #require(ParallelHorizontalAnchor.capture(ids: ["a", "b", "c", "d"], stride: 421, offset: 480))
        // when / then
        #expect(anchor.id == "b")
        #expect(anchor.offset(ids: ["a", "c", "b", "d"], stride: 501) == 1061)
        #expect(anchor.offset(ids: ["a", "c", "d"], stride: 421) == 480)
        #expect(anchor.offset(ids: [], stride: 421) == 0)
        let removed = try #require(ParallelHorizontalAnchor.capture(ids: ["a", "b", "c", "d"], stride: 421, offset: 900))
        #expect(removed.offset(ids: ["x", "y", "a", "b", "d"], stride: 421) == 1742)
        #expect(removed.offset(ids: ["x", "b", "a"], stride: 421) == 479)
    }

    @Test func givenUnknownOrEmptyViewport_whenCapturingHorizontalAnchor_thenNoInvalidIndexIsProduced() {
        // given / when / then
        #expect(ParallelHorizontalAnchor.capture(ids: [], stride: 421, offset: 0) == nil)
        #expect(ParallelHorizontalAnchor.capture(ids: ["a"], stride: 0, offset: 0) == nil)
        #expect(ParallelHorizontalAnchor.capture(ids: ["a", "b"], stride: 421, offset: -20)?.id == "a")
        #expect(ParallelHorizontalAnchor.capture(ids: ["a", "b"], stride: 421, offset: 9000)?.id == "b")
    }

    @Test func givenVerticalFrames_whenCapturingReadingAnchor_thenFirstIntersectingRowAndRelativeOffsetAreSaved() throws {
        // given
        let frames = ["a": CGRect(x: 0, y: -160, width: 420, height: 100),
                      "b": CGRect(x: 0, y: -40, width: 420, height: 100),
                      "c": CGRect(x: 0, y: 80, width: 420, height: 100)]
        // when
        let anchor = try #require(ParallelVerticalAnchor.capture(ids: ["a", "b", "c"], frames: frames, viewportHeight: 300))
        // then
        #expect(anchor.id == "b")
        #expect(anchor.relativeOffset == -40)
        #expect(anchor.resolvedID(in: ["a", "c"]) == "c")
        #expect(anchor.resolvedID(in: []) == nil)
        let shortened = ParallelVerticalAnchor(id: "b", index: 1, relativeOffset: -200)
        #expect(shortened.offset(in: CGRect(x: 0, y: 100, width: 420, height: 80)) == 179)
    }

    @Test func givenMountedHorizontalObserver_whenNativeScrollAndOrderChange_thenMeasuredViewportAndAnchorArePreserved() async throws {
        // given
        _ = NSApplication.shared
        let position = Position()
        let initialIDs = ["a", "b", "c", "d", "e"]
        let host = NSHostingView(rootView: fixture(ids: initialIDs, position: position))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 430, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil { host.layoutSubtreeIfNeeded(); return position.width > 0 }
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
        // when
        scroll.contentView.scroll(to: CGPoint(x: 480, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil { abs(position.offset - 480) < 2 }
        host.rootView = fixture(ids: ["a", "c", "b", "d", "e"], position: position)
        await waitUntil { host.layoutSubtreeIfNeeded(); return abs(position.offset - 901) < 2 }
        // then
        #expect(abs(position.offset - 901) < 2)
        #expect(position.width > 400)
        // Reattachment must emit even when geometry is unchanged: the VM resets residency
        // on teardown and needs a fresh viewport before it can reacquire activity.
        let reports = position.reports
        window.contentView = nil
        window.contentView = host
        await waitUntil { position.reports > reports }
        #expect(position.reports > reports)
    }

    @Test func givenEvictedColumn_whenMountedAgain_thenDisclosureReadingOffsetAndFollowPreferenceAreRestored() async throws {
        // given
        _ = NSApplication.shared
        let state = ParallelColumnUIState()
        state.expandedGroups = ["retained-tool"]
        let model = try column(id: "reading", rows: 20)
        let host = NSHostingView(rootView: ParallelColumnView(model: model, state: state).frame(width: 420, height: 500).id(0))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            return descendants(host)
.compactMap { $0 as? NSScrollView }
                .contains { ($0.documentView?.bounds.height ?? 0) > 2000 }
        }
        var scrollCandidate: NSScrollView?
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            guard let candidate = descendants(host).compactMap({ $0 as? NSScrollView }).first(where: {
                $0.hasVerticalScroller && ($0.documentView?.bounds.height ?? 0) > 2000
                    && abs(state.scrollOffset - $0.documentVisibleRect.minY) < 2
            }), let document = candidate.documentView else { return false }
            scrollCandidate = candidate
            return state.viewportPositioned && state.followLive.isFollowing
                && candidate.documentVisibleRect.maxY >= document.bounds.maxY - 2
        }
        let scroll = try #require(scrollCandidate)
        try requireSettledLiveViewport(scroll: scroll, state: state)
        // Establish a paused reading position through an upward native movement from the
        // settled live-follow bottom before exercising eviction and remount restoration.
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 330))
        scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            return abs(state.scrollOffset - 330) < 2 && !state.followLive.isFollowing
        }
        try #require(abs(state.scrollOffset - 330) < 2 && !state.followLive.isFollowing,
                     "The native movement must settle into a paused reading position")
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        #expect(abs(state.scrollOffset - 330) < 2)
        let anchor = try #require(state.anchor)
        host.rootView = ParallelColumnView(model: model, state: state).frame(width: 420, height: 500).id(1)
        var replacementCandidate: NSScrollView?
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            guard let replacement = descendants(host).compactMap({ $0 as? NSScrollView }).first(where: {
                      $0.hasVerticalScroller && abs(state.scrollOffset - $0.documentVisibleRect.minY) < 3
                  }),
                  (replacement.documentView?.bounds.height ?? 0) > 2000 else { return false }
            replacementCandidate = replacement
            return abs(replacement.documentVisibleRect.minY - 330) < 3
        }
        // then
        let replacement = try #require(replacementCandidate)
        #expect(abs(replacement.documentVisibleRect.minY - 330) < 3)
        #expect(state.expandedGroups == ["retained-tool"])
        #expect(!state.followLive.isFollowing)
        #expect(state.anchor?.id == anchor.id)
    }

    @Test func givenEmbeddedWorkflowActivity_whenSelectionScrollsToOffscreenColumn_thenViewportIsForwardedToItsVM() async throws {
        // given
        _ = NSApplication.shared
        let vm = ViewportVM(columns: try ["a", "b", "c", "d", "e"].map { try column(id: $0, rows: 0) })
        let host = NSHostingView(rootView: WorkflowActivityColumns(viewModel: vm, selectedTaskID: nil))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 430, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil { host.layoutSubtreeIfNeeded(); return vm.width > 400 }
        // when
        host.rootView = WorkflowActivityColumns(viewModel: vm, selectedTaskID: "c")
        await waitUntil { host.layoutSubtreeIfNeeded(); return vm.offset > 800 }
        // then
        #expect(vm.offset > 800)
        #expect(vm.width > 400)
    }

    @Test func givenPausedReading_whenColumnWidthReflows_thenVisibleAnchorAndRelativeOffsetAreRestored() async throws {
        // given
        _ = NSApplication.shared
        let state = ParallelColumnUIState()
        let model = try column(id: "reflow", rows: 20)
        let host = NSHostingView(rootView: ParallelColumnView(model: model, state: state).frame(width: 420, height: 500))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        let (scroll, narrowDocumentHeight) = try await settledReflowScroll(host: host, state: state)
        let viewportHeight = scroll.contentView.bounds.height
        let anchor = try await moveToPausedInteriorAnchor(
            host: host, scroll: scroll, state: state,
            documentHeight: narrowDocumentHeight, viewportHeight: viewportHeight)
        #expect(anchor.id != "row0")
        // when
        host.rootView = ParallelColumnView(model: model, state: state).frame(width: 650, height: 500)
        window.setContentSize(CGSize(width: 650, height: 500))
        await awaitResizedReadingPosition(host: host, scroll: scroll, state: state,
                                          expectation: ResizeExpectation(
                                            previousDocumentHeight: narrowDocumentHeight,
                                            expectedAnchor: anchor, widthMatches: { $0 > 600 }))
        let restoredOffset = scroll.documentVisibleRect.minY
        expectRestoredReadingPosition(scroll: scroll, state: state, expectedAnchor: anchor,
                                      previousDocumentHeight: narrowDocumentHeight, widthMatches: { $0 > 600 })
        let mountedAnchorFrame = try measuredAnchorRowFrame(
            in: scroll, anchor: anchor, offset: restoredOffset)
        // A real native move obtains a fresh measured anchor after restoration, rather than
        // merely asserting the saved value that the restoration phase intentionally retains.
        // Keep the move inside this measured row: when its top is above the viewport, move
        // upward; otherwise move downward from the row's measured top edge.
        let nativeMoveDelta = nativeMoveDelta(for: mountedAnchorFrame, offset: restoredOffset)
        let movedOffset = try boundedNativeMoveOffset(
            scroll: scroll, start: restoredOffset, delta: nativeMoveDelta, rowFrame: mountedAnchorFrame)
        try requireNativeMoveFitsRow(mountedAnchorFrame, targetOffset: movedOffset)
        try #require(abs(restoredOffset - movedOffset) > 5)
        let expectedMovedRelativeOffset = anchor.relativeOffset - (movedOffset - restoredOffset)
        try await performNativeAnchorMove(host: host, scroll: scroll, state: state,
                                          expectation: NativeMoveExpectation(
                                            fromOffset: restoredOffset, requestedOffset: movedOffset,
                                            anchor: anchor, expectedRelativeOffset: expectedMovedRelativeOffset))
        // Returning to the narrower column must also finish restoration with fresh geometry.
        let wideAnchor = try #require(state.anchor)
        let wideDocumentHeight = try #require(scroll.documentView?.bounds.height)
        host.rootView = ParallelColumnView(model: model, state: state).frame(width: 420, height: 500)
        window.setContentSize(CGSize(width: 420, height: 500))
        await awaitResizedReadingPosition(host: host, scroll: scroll, state: state,
                                          expectation: ResizeExpectation(
                                            previousDocumentHeight: wideDocumentHeight,
                                            expectedAnchor: wideAnchor, widthMatches: { $0 < 400 }))
        expectRestoredReadingPosition(scroll: scroll, state: state, expectedAnchor: wideAnchor,
                                      previousDocumentHeight: wideDocumentHeight, widthMatches: { $0 < 400 })
        #expect(!state.followLive.isFollowing)

        // A reverse native move must also produce fresh measured geometry before the
        // restored anchor is accepted. Move in the opposite direction while staying
        // inside the current document bounds so this cannot become a row transition.
        let reverseStartOffset = scroll.documentVisibleRect.minY
        let reverseAnchorFrame = try measuredAnchorRowFrame(
            in: scroll, anchor: wideAnchor, offset: reverseStartOffset)
        let reverseMovedOffset = try boundedNativeMoveOffset(
            scroll: scroll, start: reverseStartOffset, delta: -nativeMoveDelta, rowFrame: reverseAnchorFrame)
        try #require(abs(reverseMovedOffset - reverseStartOffset) > 5)
        try requireNativeMoveFitsRow(reverseAnchorFrame, targetOffset: reverseMovedOffset)
        let expectedReverseRelativeOffset = wideAnchor.relativeOffset - (reverseMovedOffset - reverseStartOffset)
        try await performNativeAnchorMove(host: host, scroll: scroll, state: state,
                                          expectation: NativeMoveExpectation(
                                            fromOffset: reverseStartOffset, requestedOffset: reverseMovedOffset,
                                            anchor: wideAnchor, expectedRelativeOffset: expectedReverseRelativeOffset))
    }

    @Test func givenColumnCell_whenOnlyCallbacksDiffer_thenEqualityRemainsQuietButStateAndGeometryChangesInvalidate() throws {
        // given
        let model = try column(id: "equality", rows: 2)
        let state = ParallelColumnUIState()
        let cell = ParallelColumnCell(model: model, state: state, size: CGSize(width: 420, height: 500))
        var callbackChange = model
        callbackChange.onDidPresent = {}
        // when / then
        #expect(cell == ParallelColumnCell(model: callbackChange, state: state, size: cell.size))
        #expect(cell != ParallelColumnCell(model: model, state: ParallelColumnUIState(), size: cell.size))
        #expect(cell != ParallelColumnCell(model: model, state: state, size: CGSize(width: 421, height: 500)))
    }

    private struct ResizeExpectation {
        let previousDocumentHeight: CGFloat
        let expectedAnchor: ParallelVerticalAnchor
        let widthMatches: (CGFloat) -> Bool
    }

    private struct NativeMoveExpectation {
        let fromOffset: CGFloat
        let requestedOffset: CGFloat
        let anchor: ParallelVerticalAnchor
        let expectedRelativeOffset: CGFloat
    }

    private func settledReflowScroll(
        host: NSView, state: ParallelColumnUIState
    ) async throws -> (NSScrollView, CGFloat) {
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            return descendants(host).compactMap { $0 as? NSScrollView }.contains {
                ($0.documentView?.bounds.height ?? 0) > 2000
            }
        }
        let scroll = try #require(descendants(host)
.compactMap { $0 as? NSScrollView }
            .first { $0.hasVerticalScroller && ($0.documentView?.bounds.height ?? 0) > 2000 })
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            guard let document = scroll.documentView else { return false }
            return state.viewportPositioned && state.followLive.isFollowing
                && scroll.documentVisibleRect.maxY >= document.bounds.maxY - 2
        }
        return (scroll, try #require(scroll.documentView?.bounds.height))
    }

    private func moveToPausedInteriorAnchor(
        host: NSView, scroll: NSScrollView, state: ParallelColumnUIState,
        documentHeight: CGFloat, viewportHeight: CGFloat
    ) async throws -> ParallelVerticalAnchor {
        // Move from the settled bottom to a measured interior position, leaving legal
        // room below it and capturing the mounted row identity.
        let readingOffset = max(1, min(documentHeight - viewportHeight - 100,
                                       documentHeight * 0.5))
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: readingOffset))
        scroll.reflectScrolledClipView(scroll.contentView)
        var lastReadingAnchor: ParallelVerticalAnchor?
        var stableSamples = 0
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            let current = state.anchor
            if current == lastReadingAnchor {
                stableSamples += 1
            } else {
                lastReadingAnchor = current
                stableSamples = 0
            }
            return stableSamples >= 2 && current?.id != "row0"
                && state.viewportPositioned && !state.followLive.isFollowing
                && abs(state.scrollOffset - readingOffset) < 2
        }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        try #require(state.anchor != nil && !state.followLive.isFollowing,
                     "The interior anchor must settle while paused")
        return try #require(state.anchor)
    }

    private func awaitResizedReadingPosition(
        host: NSView, scroll: NSScrollView, state: ParallelColumnUIState,
        expectation: ResizeExpectation
    ) async {
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            let documentHeight = scroll.documentView?.bounds.height ?? expectation.previousDocumentHeight
            return expectation.widthMatches(scroll.contentView.bounds.width) && state.viewportPositioned
                && abs(documentHeight - expectation.previousDocumentHeight) > 1
                && state.anchor?.id == expectation.expectedAnchor.id
        }
    }

    private func expectRestoredReadingPosition(
        scroll: NSScrollView, state: ParallelColumnUIState, expectedAnchor: ParallelVerticalAnchor,
        previousDocumentHeight: CGFloat, widthMatches: (CGFloat) -> Bool
    ) {
        #expect(widthMatches(scroll.contentView.bounds.width))
        #expect(abs((scroll.documentView?.bounds.height ?? previousDocumentHeight) - previousDocumentHeight) > 1)
        #expect(state.viewportPositioned)
        #expect(state.anchor?.id == expectedAnchor.id)
        #expect(abs((state.anchor?.relativeOffset ?? .infinity) - expectedAnchor.relativeOffset) < 3)
    }

    private func measuredAnchorRowFrame(
        in scroll: NSScrollView, anchor: ParallelVerticalAnchor, offset: CGFloat
    ) throws -> CGRect {
        let marker = "Anchor \(anchor.id):"
        let document = try #require(scroll.documentView)
        let label = try #require(descendants(scroll.documentView ?? scroll)
.compactMap { $0 as? NSTextField }
            .first { $0.stringValue.contains(marker) })
        let labelFrame = label.convert(label.bounds, to: document)
        var view: NSView? = label
        var frame = labelFrame
        while let candidate = view {
            let candidateFrame = candidate.convert(candidate.bounds, to: document)
            if candidateFrame.width > document.bounds.width * 0.5,
               candidateFrame.height > frame.height,
               candidateFrame.height < document.bounds.height * 0.5 {
                frame = candidateFrame
                break
            }
            view = candidate.superview
        }
        return frame
    }

    private func requireSettledLiveViewport(
        scroll: NSScrollView, state: ParallelColumnUIState
    ) throws {
        let document = try #require(scroll.documentView)
        try #require(state.viewportPositioned && state.followLive.isFollowing
                     && scroll.documentVisibleRect.maxY >= document.bounds.maxY - 2,
                     "The selected native scroll must be the settled live-follow viewport")
    }

    private func nativeMoveDelta(for frame: CGRect, offset: CGFloat) -> CGFloat {
        frame.minY - offset < -15 ? -12 : 12
    }

    private func requireNativeMoveFitsRow(_ frame: CGRect, targetOffset: CGFloat) throws {
        try #require(targetOffset - frame.minY > 5)
        try #require(frame.maxY - targetOffset > 5)
    }

    private func boundedNativeMoveOffset(
        scroll: NSScrollView, start: CGFloat, delta: CGFloat, rowFrame: CGRect
    ) throws -> CGFloat {
        let document = try #require(scroll.documentView)
        let documentOffset = min(max(0, document.bounds.height - scroll.contentView.bounds.height) - 1,
                                 max(1, start + delta))
        return min(rowFrame.maxY - 6, max(rowFrame.minY + 6, documentOffset))
    }

    private func performNativeAnchorMove(
        host: NSView, scroll: NSScrollView, state: ParallelColumnUIState,
        expectation: NativeMoveExpectation
    ) async throws {
        try #require(abs(expectation.requestedOffset - expectation.fromOffset) > 5)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: expectation.requestedOffset))
        scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            guard let current = state.anchor else { return false }
            return abs(state.scrollOffset - expectation.requestedOffset) < 2
                && current.id == expectation.anchor.id
                && abs(current.relativeOffset - expectation.expectedRelativeOffset) < 3
                && abs(current.relativeOffset - expectation.anchor.relativeOffset) > 5
        }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        try #require(state.anchor?.id == expectation.anchor.id)
        try #require(abs((state.anchor?.relativeOffset ?? .infinity) - expectation.expectedRelativeOffset) < 3)
        try #require(!state.followLive.isFollowing)
    }

    private func column(id: String, rows count: Int) throws -> ParallelColumnModel {
        let task = try #require(TaskInfo(.object([
            "task_id": .string(id), "backend": .string("codex"),
            "status": .string("completed"), "repo_path": .string("/tmp")
        ])))
        let paragraph = Array(repeating: "Long activity text to exercise the retained reading anchor and responsive reflow.", count: 4).joined(separator: " ")
        let text = Array(repeating: paragraph, count: 12).joined(separator: "\n\n")
        let rows = (0 ..< count).map {
            let rowText = "Anchor row\($0): \(text)"
            return ConversationTimelineRow(id: "row\($0)", taskID: id, timestamp: nil,
                                           kind: .item(PreviewFixtures.textItem(rowText, seq: $0)), live: false)
        }
        return ParallelColumnModel(id: id, task: task, title: id, subtitle: "Codex", isBusy: false,
                                   outcomeMessage: nil, showPrompt: false, prompt: nil, rows: rows,
                                   activityRows: ActivityRowsBuilder.build(from: rows), liveStep: nil,
                                   isLoading: false, summary: nil, onTapTakeover: {}, onTapOpenTask: {})
    }

    @Observable final class ViewportVM: ParallelViewModel {
        var groupName = "viewport"
        var headerSubtitle = ""
        var statusSummary: String?
        var headerPills: [String] = []
        var headerClaimCaption = ""
        var showPrompt = false
        var canCancelAll = false
        var isEmpty = false
        var footerText = ""
        var columns: [ParallelColumnModel]
        var offset: CGFloat = 0
        var width: CGFloat = 0
        init(columns: [ParallelColumnModel]) { self.columns = columns }
        func updateViewport(offset: CGFloat, width: CGFloat) { self.offset = offset; self.width = width }
        func didAppear() {}
        func didDisappear() {}
        func didTapViewPrompt() {}
        func didTapCancelAll() {}
    }

    private final class Position {
        var reports = 0
        var offset: CGFloat = 0
        var width: CGFloat = 0
    }

    private func fixture(ids: [String], position: Position) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(ids, id: \.self) { id in Text(id).frame(width: 421, height: 200) }
            }
            .background(ParallelScrollObserver(axis: .horizontal, columnIDs: ids, columnStride: 421) { offset, _, width in
                position.reports += 1
                position.offset = offset
                position.width = width
            })
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
