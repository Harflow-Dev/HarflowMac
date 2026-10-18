import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct WorkflowNativeActivityScrollChromeTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func givenNativeSubagentActivity_whenHosted_thenItsOwnVerticalScrollViewUsesThinOverlayChrome(scheme: ColorScheme) async throws {
        // given — this is the native-subagent alternate feed, which does not use ActivityFeedView.
        _ = NSApplication.shared
        let item = PreviewFixtures.textItem(
            String(repeating: "Native subagent activity remains readable while the feed scrolls. ", count: 80), seq: 1
        )
        let model = WorkflowNativeActivityModel(executionID: "execution", title: "Review", status: "running",
                                                limited: true, items: [item], hasEarlierActivity: true)
        let host = NSHostingView(rootView: WorkflowNativeActivityView(model: model)
            .preferredColorScheme(scheme)
            .frame(width: 420, height: 360))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        // when / then — discover the actual native feed scroll view, not a production test hook.
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            return descendants(host).contains { view in
                guard let scroll = view as? NSScrollView else { return false }
                return scroll.hasVerticalScroller && scroll.documentView != nil
            }
        }
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first { $0.hasVerticalScroller })
        #expect(scroll.scrollerStyle == .overlay)
        #expect(scroll.autohidesScrollers)
        #expect(scroll.verticalScroller?.controlSize == .small)
        #expect(scroll.hasVerticalScroller)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
