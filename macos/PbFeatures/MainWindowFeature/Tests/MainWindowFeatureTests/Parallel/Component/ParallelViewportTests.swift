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
        state.followLive.suspend()
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
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
        await waitUntil { state.anchor != nil }
        // when
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 330))
        scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil { abs(state.scrollOffset - 330) < 2 }
        #expect(abs(state.scrollOffset - 330) < 2)
        let anchor = try #require(state.anchor)
        host.rootView = ParallelColumnView(model: model, state: state).frame(width: 420, height: 500).id(1)
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            guard let replacement = descendants(host).compactMap({ $0 as? NSScrollView }).first,
                  (replacement.documentView?.bounds.height ?? 0) > 2000 else { return false }
            return abs(replacement.documentVisibleRect.minY - 330) < 3
        }
        // then
        let replacement = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
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
        state.followLive.suspend()
        let model = try column(id: "reflow", rows: 20)
        let host = NSHostingView(rootView: ParallelColumnView(model: model, state: state).frame(width: 420, height: 500))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            return descendants(host).compactMap { $0 as? NSScrollView }.contains { ($0.documentView?.bounds.height ?? 0) > 2000 }
        }
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
        await waitUntil { host.layoutSubtreeIfNeeded(); return state.anchor != nil && state.viewportPositioned }
        let originalHeight = try #require(scroll.documentView?.bounds.height)
        let readingOffset = originalHeight / 2 + 80
        scroll.contentView.scroll(to: CGPoint(x: 0, y: readingOffset))
        scroll.reflectScrolledClipView(scroll.contentView)
        var lastReadingAnchor: ParallelVerticalAnchor?
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            let current = state.anchor
            let settled = current == lastReadingAnchor && current?.id != "row0" && abs(state.scrollOffset - readingOffset) < 2
            lastReadingAnchor = current
            return settled
        }
        let anchor = try #require(state.anchor)
        #expect(anchor.id != "row0")
        // when
        host.rootView = ParallelColumnView(model: model, state: state).frame(width: 650, height: 500)
        window.setContentSize(CGSize(width: 650, height: 500))
        await awaitResizedReadingPosition(host: host, scroll: scroll, state: state, previousOffset: readingOffset) { $0 > 600 }
        let restoredOffset = scroll.documentVisibleRect.minY
        #expect(scroll.contentView.bounds.width > 600)
        #expect(state.viewportPositioned)
        #expect(state.anchor?.id == anchor.id)
        #expect(abs((state.anchor?.relativeOffset ?? .infinity) - anchor.relativeOffset) < 3)
        #expect(abs(restoredOffset - readingOffset) > 5)
        // A real native move obtains a fresh measured anchor after restoration, rather than
        // merely asserting the saved value that the restoration phase intentionally retains.
        scroll.contentView.scroll(to: CGPoint(x: 0, y: restoredOffset + 1))
        scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil { abs(state.scrollOffset - restoredOffset - 1) < 2 }
        // then
        #expect(state.anchor?.id == anchor.id)
        #expect(abs((state.anchor?.relativeOffset ?? .infinity) - anchor.relativeOffset + 1) < 3)
        #expect(!state.followLive.isFollowing)
        // Returning to the narrower column must also finish restoration with fresh geometry.
        let wideAnchor = try #require(state.anchor)
        let wideOffset = scroll.documentVisibleRect.minY
        host.rootView = ParallelColumnView(model: model, state: state).frame(width: 420, height: 500)
        window.setContentSize(CGSize(width: 420, height: 500))
        await awaitResizedReadingPosition(host: host, scroll: scroll, state: state, previousOffset: wideOffset) { $0 < 400 }
        #expect(state.viewportPositioned)
        #expect(state.anchor?.id == wideAnchor.id)
        #expect(abs((state.anchor?.relativeOffset ?? .infinity) - wideAnchor.relativeOffset) < 3)
        #expect(abs(scroll.documentVisibleRect.minY - wideOffset) > 5)
        #expect(!state.followLive.isFollowing)
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

    private func awaitResizedReadingPosition(
        host: NSView, scroll: NSScrollView, state: ParallelColumnUIState,
        previousOffset: CGFloat, widthMatches: (CGFloat) -> Bool
    ) async {
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            return widthMatches(scroll.contentView.bounds.width) && state.viewportPositioned
                && abs(scroll.documentVisibleRect.minY - previousOffset) > 5
        }
    }

    private func column(id: String, rows count: Int) throws -> ParallelColumnModel {
        let task = try #require(TaskInfo(.object([
            "task_id": .string(id), "backend": .string("codex"),
            "status": .string("completed"), "repo_path": .string("/tmp")
        ])))
        let paragraph = Array(repeating: "Long activity text to exercise the retained reading anchor and responsive reflow.", count: 4).joined(separator: " ")
        let text = Array(repeating: paragraph, count: 12).joined(separator: "\n\n")
        let rows = (0 ..< count).map {
            ConversationTimelineRow(id: "row\($0)", taskID: id, timestamp: nil,
                                    kind: .item(PreviewFixtures.textItem(text, seq: $0)), live: false)
        }
        return ParallelColumnModel(id: id, task: task, title: id, subtitle: "Codex", isBusy: false,
                                   outcomeMessage: nil, showPrompt: false, prompt: nil, rows: rows,
                                   activityRows: ActivityRowsBuilder.build(from: rows), liveStep: nil,
                                   isLoading: false, summary: nil, onTapTakeover: {}, onTapOpenTask: {})
    }

    @Observable final class ViewportVM: ParallelViewModel {
        var groupName = "viewport"
        var headerSubtitle = ""
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
