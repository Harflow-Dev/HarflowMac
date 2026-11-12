import AppKit
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - ParallelHeaderLayoutTests

@MainActor @Suite(.serialized) struct ParallelHeaderLayoutTests {
    @Test(arguments: [CGSize(width: 1000, height: 620), CGSize(width: 1440, height: 900)])
    func givenAGroup_whenWindowResizes_thenThereIsNoContentHeaderAndLanesStartUnderTheToolbar(_ size: CGSize) async throws {
        // given
        let vm = ParallelViewModelMock(groupName: "pi-tracking-impl", statusSummary: "1 running · 2 done")
        let fixture = RedesignHost(NavigationSplitView {
            Text("Sidebar").frame(maxWidth: .infinity, maxHeight: .infinity)
        } detail: { ParallelView(vm) }, size: size)
        defer { fixture.close() }

        // when
        await fixture.settle { fixture.descendants.contains { ($0 as? NSScrollView)?.hasHorizontalScroller == true } }
        for nextSize in [size, CGSize(width: 1000, height: 620)] {
            fixture.window.setContentSize(nextSize)
            await fixture.settle { fixture.host.bounds.size == nextSize }

            // then — no title, subtitle, pill or claim text in the content; the lanes fill from the toolbar down.
            #expect(fixture.element(vm.groupName) == nil, "the group name lives in the top bar, not the content")
            #expect(fixture.element("1 running · 2 done") == nil)
            let scroll = try #require(fixture.descendants.compactMap { $0 as? NSScrollView }.first { $0.hasHorizontalScroller })
            let scrollFrame = scroll.convert(scroll.bounds, to: nil)
            let content = fixture.window.contentLayoutRect
            // Only the toolbar's own safe-area band (about 61 pt here) sits above the lanes: no content header.
            #expect(content.maxY - scrollFrame.maxY <= 70, "nothing but the toolbar band above the lanes: \(scrollFrame.maxY) vs \(content.maxY)")
            #expect(scrollFrame.minY >= -1)
            #expect(scrollFrame.height > 100)
        }
    }
}
