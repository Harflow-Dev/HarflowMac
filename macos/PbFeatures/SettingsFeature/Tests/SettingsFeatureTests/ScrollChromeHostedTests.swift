import AppKit
import PbTestUtilities
@testable import SettingsFeature
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct ScrollChromeHostedTests {
    @Test func givenActualGroupedGeneralSettings_whenHosted_thenNativeFormChromeIsOverlaySmall() async throws {
        // given
        let fixture = makeFixture(AnyView(GeneralSettingsView(GeneralSettingsViewModelMock())))
        defer { fixture.close() }
        // when
        await waitUntil(timeout: 5) {
            fixture.host.layoutSubtreeIfNeeded()
            return !scrolls(in: fixture.host).isEmpty
        }
        let scroll = try #require(scrolls(in: fixture.host).first)
        // then
        #expect(scroll.scrollerStyle == .overlay)
        #expect(scroll.verticalScroller?.controlSize == .small)
        #expect(scroll.hasVerticalScroller)
    }

    @Test func givenActualHarnessesList_whenHosted_thenNativeListChromeIsOverlaySmall() async throws {
        // given
        let fixture = makeFixture(AnyView(HarnessesView(HarnessesViewModelMock())))
        defer { fixture.close() }
        // when
        await waitUntil(timeout: 5) {
            fixture.host.layoutSubtreeIfNeeded()
            return !scrolls(in: fixture.host).isEmpty
        }
        let scroll = try #require(scrolls(in: fixture.host).first)
        // then
        #expect(scroll.scrollerStyle == .overlay)
        #expect(scroll.verticalScroller?.controlSize == .small)
        #expect(scroll.hasVerticalScroller)
    }

    private func scrolls(in view: NSView) -> [NSScrollView] {
        descendants(view).compactMap { $0 as? NSScrollView }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func makeFixture(_ view: AnyView) -> Fixture {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: AnyView(view.frame(width: 620, height: 460)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 460),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return Fixture(host: host, window: window)
    }

    @MainActor private struct Fixture {
        let host: NSHostingView<AnyView>
        let window: NSWindow

        func close() {
            window.contentView = nil
            window.close()
        }
    }
}
