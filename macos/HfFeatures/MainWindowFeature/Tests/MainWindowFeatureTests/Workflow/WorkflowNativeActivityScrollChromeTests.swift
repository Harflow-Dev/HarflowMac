import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct WorkflowNativeActivityScrollChromeTests {
    @Test func givenEnabledComposerEdge_whenScrollingAndFocusing_thenFadeAppearsOnlyAboveEndWithoutHostedFocus() async throws {
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let scroll = NSScrollView(frame: root.bounds)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let document = EdgeTestDocument(frame: CGRect(x: 0, y: 0, width: 320, height: 1000))
        let field = NSTextField(string: "Focused activity control")
        field.frame = CGRect(x: 16, y: 500, width: 220, height: 24)
        document.addSubview(field)
        scroll.documentView = document
        root.addSubview(scroll)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        let edge = TaskComposerNativeEdge()
        defer { edge.stop() }
        #expect(window.makeFirstResponder(scroll), "The scroll view is the first responder before checking the fade")
        edge.install(in: scroll)
        edge.update(enabled: true, positioned: true)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        scroll.reflectScrolledClipView(scroll.contentView)
        let decoration = try #require(scroll.subviews.first { String(describing: type(of: $0)).contains("TaskComposerEdgeView") })
        await waitUntil(timeout: 3) { !decoration.isHidden }
        let diagnostic = "firstResponder=\(String(describing: window.firstResponder)), visible=\(scroll.documentVisibleRect), "
            + "document=\(document.bounds)"
        #expect(!decoration.isHidden, Comment(rawValue: diagnostic))
        #expect(abs(decoration.frame.height - 16) < 1)

        let endOffset = max(0, document.bounds.maxY - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: endOffset))
        scroll.reflectScrolledClipView(scroll.contentView)
        let bottomGap = document.bounds.maxY - scroll.documentVisibleRect.maxY
        #expect(bottomGap <= 1, "The clip reaches the document end: \(bottomGap)")
        await waitUntil(timeout: 3) { decoration.isHidden }
        #expect(decoration.isHidden, "The fade is absent at the document end, gap=\(bottomGap)")

        document.scrollToVisible(CGRect(x: 8, y: 300, width: 20, height: 8))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(window.makeFirstResponder(scroll))
        await waitUntil(timeout: 3) { !decoration.isHidden }
        #expect(!decoration.isHidden, "The fade returns before a hosted control takes focus")
        document.scrollToVisible(field.frame)
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(window.makeFirstResponder(field))
        await waitUntil(timeout: 3) { decoration.isHidden }
        #expect(decoration.isHidden, "The fade is absent while a hosted control owns focus")
    }

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

    private final class EdgeTestDocument: NSView {
        override var isFlipped: Bool { true }
    }
}
