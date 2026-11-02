import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct WorkflowScrollRowTests {
    private static let contentHeight: CGFloat = 40

    @Test func givenOverflowingRow_whenHosted_thenItsOwnHorizontalScrollViewUsesThinOverlayChrome() async throws {
        // given
        _ = NSApplication.shared
        let (host, window) = makeHost()
        defer { window.contentView = nil; window.close() }

        // when
        await waitUntil(timeout: 5) { rowScroll(in: host) != nil }
        let scroll = try #require(rowScroll(in: host))

        // then
        #expect(scroll.scrollerStyle == .overlay)
        #expect(scroll.autohidesScrollers)
        #expect(scroll.horizontalScroller?.controlSize == .small)
        #expect(scroll.hasHorizontalScroller)
    }

    @Test func givenHostedRow_whenScrollerStyleFallsBackToLegacy_thenOverlayIsReassertedAndHeightIsUnchanged() async throws {
        // given
        _ = NSApplication.shared
        let (host, window) = makeHost()
        defer { window.contentView = nil; window.close() }
        let expected = Self.contentHeight + WorkflowScrollRowMetrics.gutter
        await waitUntil(timeout: 5) {
            guard let scroll = rowScroll(in: host) else { return false }
            return abs(scroll.frame.height - expected) < 0.5
        }
        let scroll = try #require(rowScroll(in: host))
        let initialHeight = scroll.frame.height

        // when
        scroll.scrollerStyle = .legacy
        host.layoutSubtreeIfNeeded()
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            return scroll.scrollerStyle == .overlay
        }
        let settled = try #require(rowScroll(in: host))

        // then
        #expect(abs(initialHeight - expected) < 0.5)
        #expect(settled === scroll)
        #expect(abs(settled.frame.height - expected) < 0.5)
        #expect(settled.scrollerStyle == .overlay)
    }

    @Test func givenStandaloneLayout_whenHeightRead_thenItIncludesScrollRowGutter() {
        // given
        let expected = HfRadius.Metrics.workflowNodeSize.height + 2 * HfRadius.Metrics.spacing8
            + 2 * HfRadius.Metrics.spacing12 + WorkflowScrollRowMetrics.gutter

        // when
        let height = WorkflowStandaloneLayout.height

        // then
        #expect(WorkflowScrollRowMetrics.gutter > 0)
        #expect(height == expected)
    }

    private func makeHost() -> (NSHostingView<AnyView>, NSWindow) {
        let row = WorkflowScrollRow {
            HStack(spacing: 0) {
                ForEach(0 ..< 10, id: \.self) { _ in
                    Rectangle().frame(width: 100, height: Self.contentHeight)
                }
            }
        }
        let host = NSHostingView(rootView: AnyView(row.frame(width: 300, height: 200)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return (host, window)
    }

    private func rowScroll(in host: NSView) -> NSScrollView? {
        host.layoutSubtreeIfNeeded()
        return descendants(host).compactMap { $0 as? NSScrollView }.first {
            $0.hasHorizontalScroller && $0.documentView != nil
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
