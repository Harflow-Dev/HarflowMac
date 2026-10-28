import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import Testing

@MainActor @Suite(.serialized) struct ParallelHorizontalNativeControlTests {
    @Test(arguments: [CGFloat(0), CGFloat(300)])
    func givenMeasuredViewport_whenInsertionAndReorderOccur_thenPixelOffsetIsPreserved(offset: CGFloat) async throws {
        // given
        _ = NSApplication.shared
        let (window, scroll, document, observer, position) = try makeNativeFixture()
        defer { window.contentView = nil; window.close() }
        observer.configure(ids: ["a", "b"], stride: 421, restorationOffset: nil, restorationActive: false)
        await waitUntil { position.reports > 0 }
        scroll.contentView.scroll(to: CGPoint(x: offset, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil { abs(position.offset - offset) < 2 }
        // when
        observer.configure(ids: ["working", "a", "b"], stride: 421, restorationOffset: nil, restorationActive: false)
        document.setFrameSize(CGSize(width: 1263, height: 200))
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: document)
        observer.configure(ids: ["b", "working", "a"], stride: 421, restorationOffset: nil, restorationActive: false)
        // then
        await waitUntil { abs(position.offset - offset) < 2 }
        #expect(abs(position.offset - offset) < 2)
    }

    @Test func givenRetainedPosition_whenNativeSurfaceRemounts_thenPositionRestoresAndShrinkClamps() async throws {
        // given
        _ = NSApplication.shared
        let retained = ParallelViewportPosition()
        retained.offset = 300
        let (window, scroll, document, observer, position) = try makeNativeFixture()
        defer { window.contentView = nil; window.close() }
        observer.horizontalPosition = retained
        observer.explicitNavigationID = "a"
        observer.configure(ids: ["a", "b"], stride: 421, restorationOffset: nil, restorationActive: false)
        // when
        await waitUntil { abs(position.offset - 300) < 2 }
        #expect(abs(retained.offset - 300) < 2)
        observer.configure(ids: ["a"], stride: 421, restorationOffset: nil, restorationActive: false)
        document.setFrameSize(CGSize(width: 421, height: 200))
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: document)
        // then
        await waitUntil { abs(position.offset) < 2 }
        #expect(abs(scroll.contentView.bounds.minX) < 2)
        #expect(abs(retained.offset) < 2)
    }

    @Test(arguments: [true, false])
    func givenPendingMountRestoration_whenUserOrExplicitNavigationOccurs_thenNewPositionWins(userInput: Bool) async throws {
        // given
        _ = NSApplication.shared
        let retained = ParallelViewportPosition()
        retained.offset = 300
        let (window, scroll, document, observer, position) = try makeNativeFixture()
        defer { window.contentView = nil; window.close() }
        observer.horizontalPosition = retained
        document.setFrameSize(CGSize(width: 1, height: 200))
        observer.configure(ids: ["a", "b"], stride: 421, restorationOffset: nil, restorationActive: false)
        await waitUntil { position.reports > 0 }
        // when
        if userInput {
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        } else {
            observer.explicitNavigationID = "b"
            observer.configure(ids: ["a", "b", "c"], stride: 421, restorationOffset: nil, restorationActive: false)
        }
        document.setFrameSize(CGSize(width: userInput ? 842 : 1263, height: 200))
        scroll.contentView.scroll(to: CGPoint(x: 80, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: document)
        // then
        await waitUntil { abs(position.offset - 80) < 2 }
        #expect(abs(position.offset - 80) < 2)
    }

    @Test func givenPendingRestoration_whenKeyboardNavigationStartsWithPointerOutsideLane_thenKeyboardPositionWins() async throws {
        // given
        _ = NSApplication.shared
        let retained = ParallelViewportPosition()
        retained.offset = 300
        let (window, scroll, document, observer, position) = try makeNativeFixture()
        defer { window.contentView = nil; window.close() }
        observer.horizontalPosition = retained
        document.setFrameSize(CGSize(width: 1, height: 200))
        observer.configure(ids: ["a", "b"], stride: 421, restorationOffset: nil, restorationActive: false)
        await waitUntil { position.reports > 0 }
        window.makeFirstResponder(scroll.contentView)
        let key = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: CGPoint(x: -100, y: -100),
                                                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                context: nil, characters: key, charactersIgnoringModifiers: key,
                                                isARepeat: false, keyCode: 124))
        // when
        observer.observeHorizontalNavigationIntent(event)
        document.setFrameSize(CGSize(width: 842, height: 200))
        scroll.contentView.scroll(to: CGPoint(x: 80, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: document)
        // then
        await waitUntil { abs(position.offset - 80) < 2 }
        #expect(abs(position.offset - 80) < 2)
    }

    @Test func givenActiveUserGesture_whenMembershipChanges_thenLayoutDoesNotRearmRestoration() async throws {
        // given
        _ = NSApplication.shared
        let (window, scroll, document, observer, position) = try makeNativeFixture()
        defer { window.contentView = nil; window.close() }
        observer.configure(ids: ["a", "b"], stride: 421, restorationOffset: nil, restorationActive: false)
        await waitUntil { position.reports > 0 }
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        // when — membership changes during the gesture, before its next bounds report.
        observer.configure(ids: ["new", "a", "b"], stride: 421, restorationOffset: nil, restorationActive: false)
        scroll.contentView.scroll(to: CGPoint(x: 80, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        document.setFrameSize(CGSize(width: 1263, height: 200))
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: document)
        // then
        await waitUntil { abs(position.offset - 80) < 2 }
        #expect(abs(position.offset - 80) < 2)
    }

    @Test func givenActivePixelPreservation_whenNextInsertionReportsShiftedBoundsBeforeConfiguration_thenOriginalOffsetWins() async throws {
        // given
        _ = NSApplication.shared
        let (window, scroll, document, observer, position) = try makeNativeFixture()
        defer { window.contentView = nil; window.close() }
        document.setFrameSize(CGSize(width: 1263, height: 200))
        observer.configure(ids: ["a", "b", "c"], stride: 421, restorationOffset: nil, restorationActive: false)
        await waitUntil { position.reports > 0 }
        scroll.contentView.scroll(to: CGPoint(x: 700, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil { abs(position.offset - 700) < 2 }
        observer.configure(ids: ["first", "a", "b", "c"], stride: 421, restorationOffset: nil, restorationActive: false)
        document.setFrameSize(CGSize(width: 1684, height: 200))
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: document)
        await waitUntil { abs(position.offset - 700) < 2 }
        // when — the next document reports SwiftUI's shifted clip before observer configuration.
        document.setFrameSize(CGSize(width: 2105, height: 200))
        scroll.contentView.scroll(to: CGPoint(x: 1331, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        await waitUntil { abs(position.offset - 1331) < 2 }
        try #require(abs(position.offset - 1331) < 2)
        observer.configure(ids: ["second", "first", "a", "b", "c"], stride: 421, restorationOffset: nil, restorationActive: false)
        // then
        await waitUntil { abs(position.offset - 700) < 2 }
        #expect(abs(position.offset - 700) < 2)
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

}
