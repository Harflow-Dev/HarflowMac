import AppKit
@testable import PbUI
import Testing

// MARK: - ScrollChromeScope inset geometry

@MainActor @Suite(.serialized) struct ScrollChromeScopeInsetTests {
    @Test func givenNonFlippedBottomInset_whenMarkersMatchTheInsetViewport_thenDirectCandidateIsOwned() {
        // given
        let scroll = TestInsetScrollView(insets: NSEdgeInsets(top: 0, left: 0, bottom: 20, right: 0))
        let (root, first, second) = bracketedInsetScroll(
            scroll: scroll, wrapper: false, insetBounds: NSRect(x: 0, y: 20, width: 200, height: 130)
        )
        // when
        root.layoutSubtreeIfNeeded()
        // then
        #expect(ScrollChromeScopeDiscovery.candidate(around: first) === scroll)
        #expect(ScrollChromeScopeDiscovery.candidate(around: second) === scroll)
    }

    @Test func givenNonFlippedBottomInset_whenMarkersMatchTheInsetViewport_thenOneWrapperCandidateIsOwned() {
        // given
        let scroll = TestInsetScrollView(insets: NSEdgeInsets(top: 0, left: 0, bottom: 20, right: 0))
        let (root, first, second) = bracketedInsetScroll(
            scroll: scroll, wrapper: true, insetBounds: NSRect(x: 0, y: 20, width: 200, height: 130)
        )
        // when
        root.layoutSubtreeIfNeeded()
        // then
        #expect(ScrollChromeScopeDiscovery.candidate(around: first) === scroll)
        #expect(ScrollChromeScopeDiscovery.candidate(around: second) === scroll)
    }

    @Test func givenFlippedScrollViewWithTopInset_whenMarkersMatchTheInsetViewport_thenCandidateIsOwned() {
        // given
        let scroll = FlippedScrollView(insets: NSEdgeInsets(top: 20, left: 0, bottom: 0, right: 0))
        scroll.hasVerticalScroller = true
        scroll.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 220))
        scroll.frame = CGRect(x: 20, y: 20, width: 200, height: 150)
        let insetBounds = NSRect(x: 0, y: 20, width: 200, height: 130)
        let pairID = ScrollChromeScopePairID()
        let first = ScrollChromeScopeMarkerView(pairID: pairID)
        let second = ScrollChromeScopeMarkerView(pairID: pairID)
        first.frame = .zero
        second.frame = .zero
        [first, scroll, second].forEach(root.addSubview)
        let markerFrame = scroll.convert(insetBounds, to: root)
        first.frame = markerFrame
        second.frame = markerFrame
        // when
        root.layoutSubtreeIfNeeded()
        // then
        #expect(ScrollChromeScopeDiscovery.candidate(around: first) === scroll)
    }

    @Test func givenInsetGeometryOnTheWrongEdge_whenDiscovering_thenItFailsClosed() {
        // given
        let scroll = TestInsetScrollView(insets: NSEdgeInsets(top: 0, left: 0, bottom: 20, right: 0))
        let (root, first, _) = bracketedInsetScroll(
            scroll: scroll, wrapper: false, insetBounds: NSRect(x: 0, y: 0, width: 200, height: 130)
        )
        // when
        root.layoutSubtreeIfNeeded()
        // then
        #expect(ScrollChromeScopeDiscovery.candidate(around: first) == nil)
    }

    @Test(arguments: [
        NSEdgeInsets(top: -1, left: 0, bottom: 0, right: 0),
        NSEdgeInsets(top: .infinity, left: 0, bottom: 0, right: 0),
        NSEdgeInsets(top: 0, left: 0, bottom: 200, right: 0)
    ])
    func givenInvalidInsets_whenMarkersOnlyMatchTheInsetViewport_thenDiscoveryFailsClosed(_ insets: NSEdgeInsets) {
        // given
        let scroll = TestInsetScrollView(insets: insets)
        let (root, first, _) = bracketedInsetScroll(
            scroll: scroll, wrapper: false, insetBounds: NSRect(x: 0, y: 20, width: 200, height: 130)
        )
        // when
        root.layoutSubtreeIfNeeded()
        // then
        #expect(ScrollChromeScopeDiscovery.candidate(around: first) == nil)
    }

    @Test func givenAllZeroInsetsAndMismatchedMarkers_whenDiscovering_thenItFailsClosed() {
        // given
        let scroll = TestInsetScrollView(insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0))
        let (root, first, _) = bracketedInsetScroll(
            scroll: scroll, wrapper: false, insetBounds: NSRect(x: 0, y: 20, width: 200, height: 130)
        )
        // when
        root.layoutSubtreeIfNeeded()
        // then
        #expect(ScrollChromeScopeDiscovery.candidate(around: first) == nil)
    }

    // MARK: - Fixtures

    private func bracketedInsetScroll(
        scroll: NSScrollView,
        wrapper: Bool,
        insetBounds: NSRect
    ) -> (NSView, ScrollChromeScopeMarkerView, ScrollChromeScopeMarkerView) {
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 220))
        let pairID = ScrollChromeScopePairID()
        let first = ScrollChromeScopeMarkerView(pairID: pairID)
        let second = ScrollChromeScopeMarkerView(pairID: pairID)
        first.frame = .zero
        second.frame = .zero
        if wrapper {
            let container = NSView(frame: CGRect(x: 20, y: 20, width: 200, height: 150))
            scroll.frame = container.bounds
            container.addSubview(scroll)
            [first, container, second].forEach(root.addSubview)
        } else {
            scroll.frame = CGRect(x: 20, y: 20, width: 200, height: 150)
            [first, scroll, second].forEach(root.addSubview)
        }
        scroll.layoutSubtreeIfNeeded()
        let markerFrame = scroll.convert(insetBounds, to: root)
        first.frame = markerFrame
        second.frame = markerFrame
        return (root, first, second)
    }
}

private class TestInsetScrollView: NSScrollView {
    let simulatedInsets: NSEdgeInsets

    init(insets: NSEdgeInsets) {
        self.simulatedInsets = insets
        super.init(frame: .zero)
    }

    override var contentInsets: NSEdgeInsets {
        get { simulatedInsets }
        set {}
    }

    override var isFlipped: Bool { false }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class FlippedScrollView: TestInsetScrollView {
    override var isFlipped: Bool { true }
}
