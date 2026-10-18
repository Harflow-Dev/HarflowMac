import AppKit
@testable import MenuBarFeature
import PbTestUtilities
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct ScrollChromeHostedTests {
    @Test func givenActualMenuBarPopoverContent_whenHosted_thenItsScrollViewUsesOverlaySmallChrome() async throws {
        // given
        _ = NSApplication.shared
        let host = NSHostingView(rootView: MenuBarView(MenuBarViewModelMock.busy))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 380, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        // when
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            return descendants(host).contains { $0 is NSScrollView }
        }
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
        // then
        #expect(scroll.scrollerStyle == .overlay)
        #expect(scroll.verticalScroller?.controlSize == .small)
        #expect(scroll.hasVerticalScroller)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
