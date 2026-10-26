import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct ParallelHorizontalNativeControlTests {
    @Test func givenPendingWorkingInsertion_whenNativeLiveScrollBegins_thenUserPositionWins() async throws {
        // given
        _ = NSApplication.shared
        let (window, scroll, document, observer, position) = try makeNativeFixture()
        defer { window.contentView = nil; window.close() }
        observer.horizontalConfiguration = .init(workingColumnIDs: ["working"], contextID: "group")
        observer.configure(ids: ["a", "b"], stride: 421, restorationOffset: nil, restorationActive: false)
        await waitUntil { position.reports > 0 }

        // when
        observer.configure(ids: ["a", "working", "b"], stride: 421, restorationOffset: nil, restorationActive: false)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: CGPoint(x: 80, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        document.setFrameSize(CGSize(width: 1263, height: 200))
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: document)
        await waitUntil { abs(position.offset - 80) < 2 }

        // then
        #expect(abs(position.offset - 80) < 2)
    }

    @Test func givenPendingWorkingInsertion_whenExplicitNavigationChanges_thenPendingCorrectionIsDiscarded() async throws {
        // given
        _ = NSApplication.shared
        let (window, _, document, observer, position) = try makeNativeFixture()
        defer { window.contentView = nil; window.close() }
        observer.horizontalConfiguration = .init(workingColumnIDs: ["working"], contextID: "group")
        observer.configure(ids: ["a", "b"], stride: 421, restorationOffset: nil, restorationActive: false)
        await waitUntil { position.reports > 0 }

        // when
        observer.configure(ids: ["a", "working", "b"], stride: 421, restorationOffset: nil, restorationActive: false)
        observer.horizontalConfiguration = .init(workingColumnIDs: ["working"], contextID: "group",
                                                 explicitNavigationID: "second-selection")
        observer.configure(ids: ["a", "working", "b"], stride: 421, restorationOffset: nil, restorationActive: false)
        document.setFrameSize(CGSize(width: 1263, height: 200))
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: document)
        await waitUntil { position.reports > 1 }

        // then
        #expect(abs(position.offset) < 2)
    }

    @Test func givenEstablishedWorkingFollow_whenExplicitNavigationChanges_thenLaterReportsPreserveNavigation() async throws {
        // given — complete the first correction before navigating to another lane.
        _ = NSApplication.shared
        let (window, scroll, document, observer, position) = try makeNativeFixture()
        defer { window.contentView = nil; window.close() }
        observer.horizontalConfiguration = .init(workingColumnIDs: [], contextID: "workflow")
        observer.configure(ids: ["a", "b"], stride: 421, restorationOffset: nil, restorationActive: false)
        await waitUntil { position.reports > 0 }
        observer.horizontalConfiguration = .init(workingColumnIDs: ["b"], contextID: "workflow")
        observer.configure(ids: ["a", "b"], stride: 421, restorationOffset: nil, restorationActive: false)
        await waitUntil { position.offset > 400 }
        try #require(position.offset > 400)

        // when — explicit navigation cancels the established follow, not just a queued insertion.
        observer.horizontalConfiguration = .init(workingColumnIDs: ["b"], contextID: "workflow",
                                                 explicitNavigationID: "navigate-to-a")
        observer.configure(ids: ["a", "b"], stride: 421, restorationOffset: nil, restorationActive: false)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: document)
        await waitUntil { abs(position.offset) < 2 }

        // then — repeated layout reports must not reinstate the old follow target.
        observer.configure(ids: ["a", "b"], stride: 421, restorationOffset: nil, restorationActive: false)
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: document)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        await Task.yield()
        #expect(abs(position.offset) < 2)
    }

    @Test func givenLeadingViewport_whenCompletedColumnAppearsAtLeadingEdge_thenLogicalAnchorMovesWithoutAutoFollow() async throws {
        // given
        _ = NSApplication.shared
        let position = Position()
        let host = NSHostingView(rootView: fixture(ids: ["a", "b"], position: position,
                                                   contextID: "group"))
        let window = makeWindow(host)
        defer { window.contentView = nil; window.close() }
        await waitUntil { host.layoutSubtreeIfNeeded(); return position.width > 0 }
        let reportsBeforeInsertion = position.reports

        // when
        host.rootView = fixture(ids: ["completed", "a", "b"], position: position,
                                contextID: "group")
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            return position.reports > reportsBeforeInsertion + 1
        }

        // then
        #expect(abs(position.offset - 421) < 2)
    }

    @Test func givenSameIDs_whenCompletedLaneResumesAfterMeasuredLayout_thenFollowCorrectsLaterNativeMovement() async throws {
        // given
        _ = NSApplication.shared
        let (window, scroll, document, observer, position) = try makeNativeFixture()
        defer { window.contentView = nil; window.close() }
        observer.horizontalConfiguration = .init(workingColumnIDs: [], contextID: "group")
        observer.configure(ids: ["a", "b"], stride: 421, restorationOffset: nil, restorationActive: false)
        await waitUntil { position.reports > 0 }
        // when — IDs and width are unchanged, so this must bypass configure's geometry guard.
        observer.horizontalConfiguration = .init(workingColumnIDs: ["b"], contextID: "group")
        observer.configure(ids: ["a", "b"], stride: 421, restorationOffset: nil, restorationActive: false)
        await waitUntil { abs(position.offset - min(421, 842 - position.width)) < 2 }
        try #require(position.offset > 400)
        // A later SwiftUI clip correction can occur even after width first matched.
        scroll.contentView.scroll(to: .zero)
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: document)
        await waitUntil { abs(position.offset - min(421, 842 - position.width)) < 2 }
        // then
        #expect(position.offset > 400)
        observer.configure(ids: ["b", "a"], stride: 421, restorationOffset: nil, restorationActive: false)
        await waitUntil { abs(position.offset) < 2 }
        scroll.contentView.scroll(to: CGPoint(x: 300, y: 0))
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: document)
        #expect(abs(position.offset) < 2)
        observer.cancelHorizontalMovement()
        scroll.contentView.scroll(to: CGPoint(x: 70, y: 0))
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: document)
        #expect(abs(position.offset - 70) < 2)
    }

    @Test func givenAwayFromLeft_whenResumeReordersAndDocumentShrinks_thenOffsetStaysInsideMeasuredDocument() async throws {
        // given
        _ = NSApplication.shared
        let (window, scroll, document, observer, position) = try makeNativeFixture()
        defer { window.contentView = nil; window.close() }
        document.setFrameSize(CGSize(width: 1684, height: 200))
        observer.horizontalConfiguration = .init(workingColumnIDs: [], contextID: "group")
        observer.configure(ids: ["a", "b", "c", "d"], stride: 421, restorationOffset: nil, restorationActive: false)
        await waitUntil { position.reports > 0 }
        scroll.contentView.scroll(to: CGPoint(x: 1100, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil { position.offset > 1000 }
        // when
        observer.horizontalConfiguration = .init(workingColumnIDs: ["d"], contextID: "group")
        observer.configure(ids: ["d", "c"], stride: 421, restorationOffset: nil, restorationActive: false)
        document.setFrameSize(CGSize(width: 842, height: 200))
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: document)
        await waitUntil { position.offset <= 842 - position.width + 1 }
        // then
        #expect(scroll.contentView.bounds.minX <= document.bounds.width - scroll.contentView.bounds.width + 1)
        #expect(position.offset >= 0)
    }

    private final class Position {
        var reports = 0
        var offset: CGFloat = 0
        var width: CGFloat = 0
    }

    private func makeNativeFixture() throws -> (NSWindow, NSScrollView, NSView,
                                                  ParallelScrollObservationView, Position) {
        let position = Position()
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 430, height: 300))
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 842, height: 200))
        scroll.documentView = document
        scroll.hasHorizontalScroller = true
        let observer = ParallelScrollObservationView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        observer.axis = .horizontal
        observer.onPosition = { offset, _, width in
            position.reports += 1
            position.offset = offset
            position.width = width
        }
        document.addSubview(observer)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 430, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        scroll.layoutSubtreeIfNeeded()
        return (window, scroll, document, observer, position)
    }

    private func makeWindow(_ host: NSHostingView<some View>) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 430, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return window
    }

    private func fixture(ids: [String], position: Position, workingIDs: Set<String> = [],
                         contextID: String? = nil) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(ids, id: \.self) { id in Text(id).frame(width: 421, height: 200) }
            }
            .background(ParallelScrollObserver(axis: .horizontal, columnIDs: ids, columnStride: 421,
                                               workingColumnIDs: workingIDs, contextID: contextID) { offset, _, width in
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
