import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - ParallelViewportInsetTests

/// A lane row whose scroll view carries a leading content inset (the detail column's safe area under a floating
/// sidebar): offsets and the viewport are measured inside the inset, so offset 0 is the first lane at the inset.
@MainActor @Suite(.serialized) struct ParallelViewportInsetTests {
    private final class Position {
        var offset: CGFloat = 0
        var width: CGFloat = 0
    }

    private struct Row: View {
        let ids: [String]
        let margin: CGFloat
        let position: Position

        var body: some View {
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(ids, id: \.self) { id in Text(id).frame(width: 421, height: 200) }
                }
                .background(ParallelScrollObserver(axis: .horizontal, columnIDs: ids, columnStride: 421) { offset, _, width in
                    position.offset = offset
                    position.width = width
                })
            }
            .contentMargins(.leading, margin, for: .scrollContent)
        }
    }

    private func mount(margin: CGFloat, position: Position) -> (NSHostingView<Row>, NSWindow) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: Row(ids: ["a", "b", "c", "d"], margin: margin, position: position))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return (host, window)
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    @Test func givenALeadingInset_whenMounted_thenTheFirstLaneSitsAtTheInsetAndTheViewportExcludesIt() async throws {
        // given / when
        let position = Position()
        let (host, window) = mount(margin: 100, position: position)
        defer { window.contentView = nil; window.close() }
        await waitUntil { host.layoutSubtreeIfNeeded(); return position.width > 0 }
        await waitUntil { host.layoutSubtreeIfNeeded(); return position.width > 0 && abs(position.width - 500) < 2 }
        let scroll = try #require(scrollView(in: host))

        // then — offset 0 is the first lane at the inset, not the raw clip origin
        #expect(abs(scroll.contentInsets.left - 100) < 0.5)
        #expect(abs(scroll.contentView.bounds.minX + 100) < 0.5, "the clip starts at -inset, so lane 1 is at the inset: \(scroll.contentView.bounds.minX)")
        #expect(abs(position.offset) < 0.5)
        #expect(abs(position.width - 500) < 2, "the viewport excludes the inset: \(position.width)")
    }

    @Test func givenALeadingInset_whenTheRowScrolls_thenTheOffsetIsMeasuredInsideTheInset() async throws {
        // given
        let position = Position()
        let (host, window) = mount(margin: 100, position: position)
        defer { window.contentView = nil; window.close() }
        await waitUntil { host.layoutSubtreeIfNeeded(); return abs(position.width - 500) < 2 }
        let scroll = try #require(scrollView(in: host))

        // when — a live scroll to logical offset 300
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: CGPoint(x: 200, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)

        // then
        await waitUntil { abs(position.offset - 300) < 2 }
        #expect(abs(position.offset - 300) < 2, "raw origin 200 with a 100 inset is logical 300: \(position.offset)")
    }

    @Test func givenALeadingInset_whenTheInsetIsRemoved_thenTheLogicalPositionIsKept() async throws {
        // given — the sidebar is shown, then collapses
        let position = Position()
        let (host, window) = mount(margin: 100, position: position)
        defer { window.contentView = nil; window.close() }
        await waitUntil { host.layoutSubtreeIfNeeded(); return abs(position.width - 500) < 2 }
        let scroll = try #require(scrollView(in: host))

        // when
        host.rootView = Row(ids: ["a", "b", "c", "d"], margin: 0, position: position)
        await waitUntil { host.layoutSubtreeIfNeeded(); return abs(position.width - 600) < 2 }

        // then — still at the first lane, now at raw origin 0
        #expect(abs(position.offset) < 0.5)
        #expect(abs(scroll.contentView.bounds.minX) < 0.5, "raw origin \(scroll.contentView.bounds.minX)")
    }
}
