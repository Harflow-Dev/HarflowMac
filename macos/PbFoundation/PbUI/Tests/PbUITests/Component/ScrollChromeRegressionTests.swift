import AppKit
import PbTestUtilities
@testable import PbUI
import Testing

@MainActor @Suite(.serialized) struct ScrollChromeRegressionTests {
    @Test func givenLegacyChrome_whenAnActivityFeedAttaches_thenNativeOverlayChromeIsAppliedAndRestored() throws {
        // given
        let harness = try makeHarness()
        defer { harness.close() }
        let scroll = harness.scroll
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        scroll.verticalScroller?.controlSize = .regular
        scroll.horizontalScroller?.controlSize = .regular
        let document = try #require(scroll.documentView)
        let content = scroll.contentView

        // when
        let token = ScrollChromeOwner.attach(to: scroll)

        // then — only native presentation fields change; the feed's document, clip view and
        // scrolling capability remain the same.
        #expect(scroll.scrollerStyle == .overlay)
        #expect(scroll.autohidesScrollers)
        #expect(scroll.verticalScroller?.controlSize == .small)
        // The monitor-wide amendment sizes both already-enabled native axes.
        #expect(scroll.horizontalScroller?.controlSize == .small)
        #expect(scroll.hasVerticalScroller)
        #expect(scroll.hasHorizontalScroller)
        #expect(scroll.documentView === document)
        #expect(scroll.contentView === content)

        // when
        ScrollChromeOwner.detach(token)

        // then
        #expect(scroll.scrollerStyle == .legacy)
        #expect(!scroll.autohidesScrollers)
        #expect(scroll.verticalScroller?.controlSize == .regular)
        #expect(scroll.horizontalScroller?.controlSize == .regular)
    }

    @Test func givenOverlappingFeedAttachments_whenOneDetaches_thenTheRemainingOwnerKeepsOverlayChrome() throws {
        // given
        let harness = try makeHarness()
        defer { harness.close() }
        let scroll = harness.scroll
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false

        let first = ScrollChromeOwner.attach(to: scroll)
        let second = ScrollChromeOwner.attach(to: scroll)

        // when
        ScrollChromeOwner.detach(first)

        // then — an overlapping representable must not restore the legacy gutter underneath the
        // still-mounted feed attachment.
        #expect(scroll.scrollerStyle == .overlay)
        #expect(scroll.autohidesScrollers)
        #expect(ScrollChromeRegistry.registry.object(forKey: scroll) != nil)

        // when
        ScrollChromeOwner.detach(second)

        // then
        #expect(scroll.scrollerStyle == .legacy)
        #expect(!scroll.autohidesScrollers)
        #expect(ScrollChromeRegistry.registry.object(forKey: scroll) == nil)
    }

    @Test func givenTheSameAttachmentTokenIsDetachedTwice_whenAnotherAttachmentRemains_thenOverlayOwnershipStaysLive() throws {
        // given
        let harness = try makeHarness()
        defer { harness.close() }
        let scroll = harness.scroll
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false

        let first = ScrollChromeOwner.attach(to: scroll)
        let second = ScrollChromeOwner.attach(to: scroll)

        // when — a stale cleanup callback repeats the first token
        ScrollChromeOwner.detach(first)
        ScrollChromeOwner.detach(first)

        // then — the second live attachment still owns the native presentation
        #expect(scroll.scrollerStyle == .overlay)
        #expect(scroll.autohidesScrollers)
        #expect(ScrollChromeRegistry.registry.object(forKey: scroll) != nil)

        // when
        ScrollChromeOwner.detach(second)

        // then
        #expect(scroll.scrollerStyle == .legacy)
        #expect(!scroll.autohidesScrollers)
    }

    @Test func givenAPreferredStyleNotificationWhileOwned_whenNativeStyleChanges_thenOverlayIsReassertedAndCurrentPreferenceRestores() async throws {
        // given
        let harness = try makeHarness()
        defer { harness.close() }
        let scroll = harness.scroll
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        let token = ScrollChromeOwner.attach(to: scroll)

        // when — AppKit normally changes the preferred style before the owner reasserts the
        // activity-feed overlay. Simulate that sequence without changing a global preference.
        scroll.scrollerStyle = .legacy
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        await waitUntil { scroll.scrollerStyle == .overlay }
        ScrollChromeOwner.detach(token)

        // then — this test only pins that the current preferred style is used after notification;
        // it never mutates or assumes the machine's global scrollbar preference.
        #expect(scroll.scrollerStyle == NSScroller.preferredScrollerStyle)
    }

    @Test func givenTheScrollViewHasLostItsWindow_whenTheLastAttachmentDetaches_thenTeardownDoesNotRewriteChrome() throws {
        // given
        let harness = try makeHarness()
        defer { harness.close() }
        let scroll = harness.scroll
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        let token = ScrollChromeOwner.attach(to: scroll)
        harness.window.contentView = nil
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true

        // when
        ScrollChromeOwner.detach(token)

        // then — no visible consumer exists, so teardown must not trigger a reflow write into the
        // retained feed. A later attachment captures this current state afresh.
        #expect(scroll.scrollerStyle == .overlay)
        #expect(scroll.autohidesScrollers)
        #expect(ScrollChromeRegistry.registry.object(forKey: scroll) == nil)
    }

    private func makeHarness() throws -> Harness {
        _ = NSApplication.shared
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 720))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        return Harness(scroll: scroll, window: window)
    }

    @MainActor private struct Harness {
        let scroll: NSScrollView
        let window: NSWindow

        func close() {
            window.contentView = nil
            window.close()
        }
    }
}
