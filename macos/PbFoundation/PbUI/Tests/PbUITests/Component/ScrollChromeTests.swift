import AppKit
import PbTestUtilities
@testable import PbUI
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct ScrollChromeTests {
    @Test func givenTwoAttachments_whenLastAttachmentDetaches_thenOriginalChromeAndIdentityReturn() throws {
        // given
        _ = NSApplication.shared
        let scroll = makeScroll(vertical: true, horizontal: true)
        let document = try #require(scroll.documentView)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        scroll.verticalScroller?.controlSize = .regular
        scroll.horizontalScroller?.controlSize = .regular
        scroll.contentView.bounds.origin = CGPoint(x: 0, y: 40)
        let originalOrigin = scroll.contentView.bounds.origin
        let original = ScrollChromeOwner.OriginalChrome(
            scrollerStyle: .legacy, autohidesScrollers: false,
            verticalControlSize: .regular, horizontalControlSize: .regular
        )

        // when
        let first = ScrollChromeOwner.attach(to: scroll)
        let second = ScrollChromeOwner.attach(to: scroll)
        #expect(scroll.scrollerStyle == .overlay)
        #expect(scroll.autohidesScrollers)
        #expect(scroll.verticalScroller?.controlSize == .small)
        #expect(scroll.horizontalScroller?.controlSize == .small)
        #expect(scroll.documentView === document)
        #expect(scroll.contentView.bounds.origin == originalOrigin)

        // then
        ScrollChromeOwner.detach(first)
        #expect(scroll.scrollerStyle == .overlay)
        #expect(scroll.verticalScroller?.controlSize == .small)
        ScrollChromeOwner.detach(second)
        #expect(scroll.scrollerStyle == original.scrollerStyle)
        #expect(scroll.autohidesScrollers == original.autohidesScrollers)
        #expect(scroll.verticalScroller?.controlSize == original.verticalControlSize)
        #expect(scroll.horizontalScroller?.controlSize == original.horizontalControlSize)
        #expect(scroll.documentView === document)
        #expect(scroll.contentView.bounds.origin == originalOrigin)
    }

    @Test func givenDisabledHorizontalAxis_whenAttached_thenOnlyEnabledAxisChanges() throws {
        // given
        let scroll = makeScroll(vertical: true, horizontal: false)
        let horizontalSize = scroll.horizontalScroller?.controlSize
        let document = try #require(scroll.documentView)
        // when
        let token = ScrollChromeOwner.attach(to: scroll)
        defer { ScrollChromeOwner.detach(token) }

        // then
        #expect(scroll.hasVerticalScroller)
        #expect(!scroll.hasHorizontalScroller)
        #expect(scroll.verticalScroller?.controlSize == .small)
        #expect(scroll.horizontalScroller?.controlSize == horizontalSize)
        #expect(scroll.documentView === document)
    }

    @Test func givenBothAxesDisabled_whenAttached_thenNoScrollerIsManufactured() {
        // given
        let scroll = makeScroll(vertical: false, horizontal: false)
        let vertical = scroll.verticalScroller
        let horizontal = scroll.horizontalScroller
        // when
        let token = ScrollChromeOwner.attach(to: scroll)
        // then
        #expect(!scroll.hasVerticalScroller)
        #expect(!scroll.hasHorizontalScroller)
        #expect(scroll.verticalScroller === vertical)
        #expect(scroll.horizontalScroller === horizontal)
        ScrollChromeOwner.detach(token)
    }

    @Test func givenPreferredStyleNotification_whenAttached_thenOverlayIsReasserted() async {
        // given
        let scroll = makeScroll(vertical: true, horizontal: false)
        let window = makeWindow(for: scroll)
        defer { close(window) }
        let token = ScrollChromeOwner.attach(to: scroll)
        defer { ScrollChromeOwner.detach(token) }
        // when
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        // A later native reset is the important ordering: the preference notification must not
        // be the only signal that keeps the owner alive.
        await drainMainQueue(cycles: 2, scroll: scroll)
        let preferred = NSScroller.preferredScrollerStyle
        scroll.scrollerStyle = .legacy
        await waitUntil(timeout: 1) { scroll.scrollerStyle == .overlay }
        // then
        #expect(scroll.scrollerStyle == .overlay)
        ScrollChromeOwner.detach(token)
        #expect(scroll.scrollerStyle == preferred)
    }

    @Test func givenOwnedScrollView_whenNativeStyleIsReset_thenDeferredObservationRestoresOverlay() async {
        // given
        let scroll = makeScroll(vertical: true, horizontal: true)
        let window = makeWindow(for: scroll)
        defer { close(window) }
        let token = ScrollChromeOwner.attach(to: scroll)
        defer { ScrollChromeOwner.detach(token) }
        #expect(scroll.scrollerStyle == .overlay)

        // when — this models AppKit/SwiftUI changing the public native style after attachment.
        scroll.scrollerStyle = .legacy

        // then — the owner observes the public change and reasserts on a later main-queue turn.
        await waitUntil(timeout: 1) { scroll.scrollerStyle == .overlay }
        #expect(scroll.scrollerStyle == .overlay)
    }

    @Test func givenBurstOfNativeStyleResets_whenOwnerIsLive_thenChromeSettlesOverlayWithoutRepeatedWrites() async {
        // given
        let scroll = makeScroll(vertical: true, horizontal: false)
        let window = makeWindow(for: scroll)
        defer { close(window) }
        let token = ScrollChromeOwner.attach(to: scroll)
        defer { ScrollChromeOwner.detach(token) }
        var observedStyles: [NSScroller.Style] = []
        let observation = scroll.observe(\NSScrollView.scrollerStyle, options: [.new]) { object, _ in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                observedStyles.append(object.scrollerStyle)
            }
        }
        defer { observation.invalidate() }

        // when — several external writes arrive before the deferred owner pass can run.
        for _ in 0 ..< 4 {
            scroll.scrollerStyle = .legacy
            scroll.scrollerStyle = .legacy
        }

        // then — the final state is stable and the owner has not created a self-sustaining loop.
        await waitUntil(timeout: 1) { scroll.scrollerStyle == .overlay }
        let countAfterSettling = observedStyles.count
        await drainMainQueue(cycles: 4, scroll: scroll)
        #expect(scroll.scrollerStyle == .overlay)
        #expect(observedStyles.last == .overlay)
        #expect(observedStyles.count == countAfterSettling)
        #expect(observedStyles.filter { $0 == .overlay }.count == 1)
    }

    @Test func givenPendingNativeReset_whenLastTokenDetaches_thenTeardownRestoresOriginalAndCancelsDeferredWork() async {
        // given
        let scroll = makeScroll(vertical: true, horizontal: false)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        scroll.scrollerStyle = .legacy
        let token = ScrollChromeOwner.attach(to: scroll)
        scroll.scrollerStyle = .legacy

        // when — teardown wins before the observation's deferred delivery.
        ScrollChromeOwner.detach(token)
        await drainMainQueue(cycles: 4, scroll: scroll)

        // then — late delivery cannot reacquire ownership or rewrite the restored native style.
        #expect(scroll.scrollerStyle == .legacy)
        #expect(ScrollChromeRegistry.registry.object(forKey: scroll) == nil)
    }

    @Test func givenOffWindowScrollView_whenLastAttachmentDetaches_thenOwnershipReleasesWithoutReflow() {
        // given
        let scroll = makeScroll(vertical: true, horizontal: false)
        scroll.scrollerStyle = .legacy
        let token = ScrollChromeOwner.attach(to: scroll)
        #expect(scroll.scrollerStyle == .overlay)
        // when
        ScrollChromeOwner.detach(token)
        // then
        #expect(scroll.scrollerStyle == .overlay)
    }

    @Test func givenOffWindowOwnedScrollView_whenNativeStyleResets_thenObserverDoesNotReassert() async {
        // given
        let scroll = makeScroll(vertical: true, horizontal: false)
        let token = ScrollChromeOwner.attach(to: scroll)
        defer { ScrollChromeOwner.detach(token) }

        // when — an off-window native view has no visible consumer to restyle.
        scroll.scrollerStyle = .legacy
        var drained = false
        DispatchQueue.main.async { drained = true }
        await waitUntil(timeout: 1) { drained }

        // then
        #expect(scroll.scrollerStyle == .legacy)
    }

    @Test func givenPendingReset_whenWindowIsRemoved_thenDeferredObservationDoesNotReassert() async {
        // given
        let scroll = makeScroll(vertical: true, horizontal: false)
        let window = makeWindow(for: scroll)
        let token = ScrollChromeOwner.attach(to: scroll)
        scroll.scrollerStyle = .legacy
        window.contentView = nil

        // when
        await drainMainQueue(cycles: 4, scroll: scroll)

        // then
        #expect(scroll.scrollerStyle == .legacy)
        ScrollChromeOwner.detach(token)
        close(window)
    }

    @Test func givenPendingReset_whenOwnedAxisIsDisabled_thenDeferredObservationDoesNotReassert() async {
        // given
        let scroll = makeScroll(vertical: true, horizontal: false)
        let window = makeWindow(for: scroll)
        defer { close(window) }
        let token = ScrollChromeOwner.attach(to: scroll)
        scroll.scrollerStyle = .legacy
        scroll.hasVerticalScroller = false

        // when
        await drainMainQueue(cycles: 4, scroll: scroll)

        // then
        #expect(!scroll.hasVerticalScroller)
        #expect(scroll.scrollerStyle == .legacy)
        ScrollChromeOwner.detach(token)
    }

    @Test func givenTwoTokens_whenNativeStyleResets_thenDetachOneKeepsTheOtherOwnerLive() async {
        // given
        let scroll = makeScroll(vertical: true, horizontal: false)
        let window = makeWindow(for: scroll)
        defer { close(window) }
        let first = ScrollChromeOwner.attach(to: scroll)
        let second = ScrollChromeOwner.attach(to: scroll)
        scroll.scrollerStyle = .legacy
        await waitUntil(timeout: 1) { scroll.scrollerStyle == .overlay }

        // when
        ScrollChromeOwner.detach(first)

        // then
        #expect(scroll.scrollerStyle == .overlay)
        #expect(ScrollChromeRegistry.registry.object(forKey: scroll) != nil)
        ScrollChromeOwner.detach(second)
    }

    private func makeScroll(vertical: Bool, horizontal: Bool) -> NSScrollView {
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        scroll.hasVerticalScroller = vertical
        scroll.hasHorizontalScroller = horizontal
        scroll.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        scroll.layoutSubtreeIfNeeded()
        return scroll
    }

    private func makeWindow(for scroll: NSScrollView) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        return window
    }

    private func close(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    private func drainMainQueue(cycles: Int, scroll: NSScrollView) async {
        var completed = 0
        await waitUntil(timeout: 1) {
            scroll.layoutSubtreeIfNeeded()
            scroll.displayIfNeeded()
            completed += 1
            return completed >= cycles
        }
    }
}
