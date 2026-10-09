import AppKit
@testable import MainWindowFeature
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct SidebarWindowLayoutTests {
    @Test func givenPopulatedSplitSidebar_whenWindowedAndResized_thenSearchAndRowsStayBelowWindowControls() async throws {
        // given
        _ = NSApplication.shared
        let vm = SidebarViewModelMock()
        vm.savedWorkflows = (0 ..< 20).map { WorkflowRecord(raw: ["name": .string("Workflow \($0)")]) }
        let host = NSHostingView(rootView: NavigationSplitView {
            SidebarView(vm).navigationSplitViewColumnWidth(min: 240, ideal: 272, max: 340)
        } detail: { Text("Detail") }.frame(minWidth: 1000, minHeight: 620).modifier(LayoutHiddenTitle()).withPresentationContext())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "sidebar-layout")
        window.toolbarStyle = .unified
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        // when / then
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for size in [NSSize(width: 1000, height: 620), NSSize(width: 1300, height: 850)] {
                window.setContentSize(size)
                await waitUntil {
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                    host.layoutSubtreeIfNeeded()
                    return descendants(host).contains { ($0 as? NSTextField)?.placeholderString == "Search loaded history" }
                }
                let search = try #require(descendants(host).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Search loaded history" })
                let close = try #require(window.standardWindowButton(.closeButton))
                let searchFrame = search.convert(search.bounds, to: nil)
                let closeFrame = close.convert(close.bounds, to: nil)
                #expect(searchFrame.maxY <= window.contentLayoutRect.maxY, "Search must remain within the native content layout area")
                let outline = try #require(descendants(host).compactMap { $0 as? NSOutlineView }.first)
                let firstRow = outline.convert(outline.rect(ofRow: 0), to: nil)
                #expect(firstRow.maxY < searchFrame.minY, "Workflows must stay below search and filter")
                #expect(searchFrame.maxY < closeFrame.minY, "Search must stay below window controls: search=\(searchFrame), close=\(closeFrame)")
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

private struct LayoutHiddenTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.toolbar(removing: .title) } else { content }
    }
}
