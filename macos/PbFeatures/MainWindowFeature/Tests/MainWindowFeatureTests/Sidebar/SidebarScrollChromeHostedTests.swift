import AppKit
@testable import MainWindowFeature
import PbCommon
import PbTestUtilities
@testable import PbUI
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct SidebarScrollChromeHostedTests {
    @Test func givenActualSidebarList_whenHosted_thenItsNativeListKeepsOverlayChromeThroughRows() async throws {
        // given
        _ = NSApplication.shared
        let model = SidebarViewModelMock(sections: overflowingSections())
        let host = NSHostingView(rootView: AnyView(SidebarView(model).frame(width: 300, height: 700)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        // when
        await waitUntil(timeout: 5) { descendants(host).compactMap { $0 as? NSOutlineView }.first != nil }
        await drainSidebar(host, cycles: 4)
        await waitUntil(timeout: 5) { settledSidebar(host) != nil }
        let outline = try #require(descendants(host).compactMap { $0 as? NSOutlineView }.first)
        let scroll = try #require(outline.enclosingScrollView)
        // then
        #expect(scroll.scrollerStyle == .overlay)
        #expect(scroll.verticalScroller?.controlSize == .small)
        #expect(scroll.documentView != nil)
        #expect(scroll.hasVerticalScroller)
        #expect(outline.numberOfRows > 0)

        let baseline = SidebarBaseline(
            outline: outline, scroll: scroll, document: try #require(scroll.documentView),
            selection: model.selection, taskCount: model.loadOlderTasksTapCount,
            workflowCount: model.loadOlderWorkflowsTapCount
        )

        try await assertSidebarTransitions(
            model: model, host: host, baseline: baseline
        )
    }

    @Test func givenOverflowingSidebar_whenRowsAndWindowChange_thenChromeSettles() async throws {
        // given
        _ = NSApplication.shared
        let model = SidebarViewModelMock(sections: overflowingSections())
        let host = NSHostingView(rootView: AnyView(SidebarView(model).frame(width: 300)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        host.autoresizingMask = [.width, .height]
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            guard let outline = descendants(host).compactMap({ $0 as? NSOutlineView }).first,
                  let scroll = outline.enclosingScrollView
            else { return false }
            return hasOverflowingDocument(scroll)
        }
        let outline = try #require(descendants(host).compactMap { $0 as? NSOutlineView }.first)
        let scroll = try #require(outline.enclosingScrollView)
        let document = try #require(scroll.documentView)
        var observedCurrent: [NSScroller.Style] = []
        var observedPreferred: [NSScroller.Style] = []
        let observation = scroll.observe(\NSScrollView.scrollerStyle, options: [.old, .new]) { object, _ in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                observedCurrent.append(object.scrollerStyle)
                observedPreferred.append(NSScroller.preferredScrollerStyle)
            }
        }
        defer { observation.invalidate() }
        await drainSidebar(host, cycles: 4)
        await waitUntil(timeout: 5) { settledSidebar(host) != nil }
        let initial = viewportSnapshot(scroll, document: document)
        let initialEventCount = observedCurrent.count

        // when — a real row transition followed by a real window resize, with no native setters.
        model.sections = []
        model.emptyStateMessage = "No active tasks"
        await drainSidebar(host, cycles: 4)
        await waitUntil(timeout: 5) { settledSidebar(host) != nil }
        model.sections = overflowingSections()
        model.emptyStateMessage = nil
        window.setContentSize(NSSize(width: 300, height: 420))
        await drainSidebar(host, cycles: 4)
        await waitUntil(timeout: 5) {
            guard let settled = settledSidebar(host), hasOverflowingDocument(settled.1) else { return false }
            return settled.1.documentView === document
        }
        await drainSidebar(host, cycles: 4)
        let settledEventCount = observedCurrent.count
        await drainSidebar(host, cycles: 4)

        // then — the native viewport remains the same owned scroll view and settles on overlay.
        let resized = viewportSnapshot(scroll, document: document)
        assertSettledViewport(
            resized, initial: initial, scroll: scroll,
            evidence: StyleEvidence(
                current: observedCurrent, preferred: observedPreferred,
                initialCount: initialEventCount, settledCount: settledEventCount
            )
        )
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func settledSidebar(_ host: NSView) -> (NSOutlineView, NSScrollView)? {
        host.layoutSubtreeIfNeeded()
        guard let outline = descendants(host).compactMap({ $0 as? NSOutlineView }).first,
              let scroll = outline.enclosingScrollView,
              outline.numberOfRows > 0,
              settledNativeEntries(outline),
              scroll.scrollerStyle == .overlay,
              scroll.verticalScroller?.controlSize == .small
        else { return nil }
        return (outline, scroll)
    }

    private func settledNativeEntries(_ outline: NSOutlineView) -> Bool {
        guard let coordinator = outline.delegate as? SidebarNativeList.Coordinator else { return false }
        return coordinator.reconciliation == nil
            && coordinator.detached == nil
            && coordinator.pendingInput == nil
            && coordinator.settledGeneration == coordinator.generation
            && coordinator.boxesByID.values.allSatisfy { !$0.entry.isFading }
    }

    private func hasOverflowingDocument(_ scroll: NSScrollView) -> Bool {
        guard let document = scroll.documentView else { return false }
        let viewport = scroll.contentView.bounds.size
        let bounds = document.bounds.size
        let content = scroll.contentSize
        return bounds.height > viewport.height + 1
            && content.height >= viewport.height
            && scroll.hasVerticalScroller
    }

    private func drainSidebar(_ host: NSView, cycles: Int) async {
        var completed = 0
        await waitUntil(timeout: 1) {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            completed += 1
            return completed >= cycles
        }
    }

    private func overflowingSections() -> [SidebarSection] {
        let rows = (0 ..< 40).map { index in
            SidebarItem.task(TaskRowModel(
                id: "overflow-\(index)", backend: "codex", title: "Overflow row \(index)",
                status: .completed, repoName: "repo", ageText: "1h", indent: 0
            ))
        }
        return [SidebarSection(bucket: .today, items: rows)]
    }

    private func viewportSnapshot(_ scroll: NSScrollView, document: NSView) -> ViewportSnapshot {
        ViewportSnapshot(
            scrollIdentity: ObjectIdentifier(scroll), documentIdentity: ObjectIdentifier(document),
            clipWidth: scroll.contentView.bounds.width, scrollBoundsWidth: scroll.bounds.width,
            boundsWidth: document.bounds.width,
            contentWidth: scroll.contentSize.width, clipHeight: scroll.contentView.bounds.height,
            documentHeight: document.bounds.height, contentHeight: scroll.contentSize.height
        )
    }

    private func assertSettledViewport(
        _ resized: ViewportSnapshot,
        initial: ViewportSnapshot,
        scroll: NSScrollView,
        evidence: StyleEvidence
    ) {
        #expect(scroll.scrollerStyle == .overlay)
        #expect(scroll.verticalScroller?.controlSize == .small)
        #expect(resized.scrollIdentity == initial.scrollIdentity)
        #expect(resized.documentIdentity == initial.documentIdentity)
        #expect(resized.clipHeight < initial.clipHeight)
        #expect(resized.documentHeight > resized.clipHeight)
        #expect(resized.contentHeight >= resized.clipHeight)
        #expect(abs(resized.clipWidth - initial.clipWidth) <= 1)
        #expect(abs(resized.scrollBoundsWidth - initial.scrollBoundsWidth) <= 1)
        #expect(abs(resized.contentWidth - initial.contentWidth) <= 1)
        #expect(abs(resized.clipWidth - resized.scrollBoundsWidth) <= 1)
        #expect(abs(resized.clipWidth - resized.contentWidth) <= 1)
        #expect(evidence.current.count >= evidence.initialCount)
        #expect(evidence.current.count == evidence.settledCount)
        #expect(evidence.current.count == evidence.preferred.count)
    }

    private func replaceSidebar(
        model: SidebarViewModelMock,
        host: NSHostingView<AnyView>,
        sections: [SidebarSection],
        emptyMessage: String?
    ) async throws -> (NSOutlineView, NSScrollView) {
        model.sections = sections
        model.emptyStateMessage = emptyMessage
        host.rootView = AnyView(SidebarView(model).frame(width: 300, height: 700))
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            return descendants(host).compactMap { $0 as? NSOutlineView }.first != nil
        }
        let outline = try #require(descendants(host).compactMap { $0 as? NSOutlineView }.first)
        return (outline, try #require(outline.enclosingScrollView))
    }

    private func assertSidebarTransitions(
        model: SidebarViewModelMock,
        host: NSHostingView<AnyView>,
        baseline: SidebarBaseline
    ) async throws {
        // when
        let (emptyOutline, emptyScroll) = try await replaceSidebar(
            model: model, host: host, sections: [], emptyMessage: "No active tasks"
        )
        await drainSidebar(host, cycles: 4)
        await waitUntil(timeout: 5) { settledSidebar(host) != nil }
        let emptyRowCount = emptyOutline.numberOfRows
        // then
        #expect(emptyRowCount >= 2)
        #expect(model.emptyStateMessage == "No active tasks")
        #expect(emptyScroll.scrollerStyle == .overlay)
        #expect(emptyScroll.verticalScroller?.controlSize == .small)

        // when
        let (populatedOutline, populatedScroll) = try await replaceSidebar(
            model: model, host: host, sections: overflowingSections(), emptyMessage: nil
        )
        await drainSidebar(host, cycles: 4)
        // then
        #expect(populatedOutline === baseline.outline)
        #expect(populatedScroll === baseline.scroll)
        #expect(populatedScroll.scrollerStyle == .overlay)
        #expect(populatedScroll.verticalScroller?.controlSize == .small)
        #expect(populatedScroll.documentView === baseline.document)
        #expect(populatedOutline.numberOfRows >= 40)
        #expect(hasOverflowingDocument(populatedScroll))

        // when
        let (finalOutline, finalScroll) = try await replaceSidebar(
            model: model, host: host, sections: [], emptyMessage: "No active tasks"
        )
        await drainSidebar(host, cycles: 4)
        await waitUntil(timeout: 5) { settledSidebar(host) != nil }
        // then
        #expect(finalOutline.numberOfRows == emptyRowCount)
        #expect(model.emptyStateMessage == "No active tasks")
        #expect(finalScroll.scrollerStyle == .overlay)
        #expect(finalScroll.verticalScroller?.controlSize == .small)
        #expect(emptyOutline === baseline.outline)
        #expect(emptyScroll === baseline.scroll)
        #expect(finalOutline === baseline.outline)
        #expect(finalScroll === baseline.scroll)
        #expect(finalScroll.documentView === baseline.document)
        #expect(model.selection == baseline.selection)
        #expect(model.loadOlderTasksTapCount == baseline.taskCount)
        #expect(model.loadOlderWorkflowsTapCount == baseline.workflowCount)
    }

}

private struct SidebarBaseline {
    let outline: NSOutlineView
    let scroll: NSScrollView
    let document: NSView
    let selection: MonitorDestination?
    let taskCount: Int
    let workflowCount: Int
}

private struct ViewportSnapshot {
    let scrollIdentity: ObjectIdentifier
    let documentIdentity: ObjectIdentifier
    let clipWidth: CGFloat
    let scrollBoundsWidth: CGFloat
    let boundsWidth: CGFloat
    let contentWidth: CGFloat
    let clipHeight: CGFloat
    let documentHeight: CGFloat
    let contentHeight: CGFloat
}

private struct StyleEvidence {
    let current: [NSScroller.Style]
    let preferred: [NSScroller.Style]
    let initialCount: Int
    let settledCount: Int
}
