import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct SidebarWindowLayoutTests {
    @Test func givenM04SplitSidebar_whenWindowedAndResized_thenIndependentListsStayWithinContent() async throws {
        // given
        _ = NSApplication.shared
        let vm = SidebarViewModelMock()
        vm.sections = [.init(bucket: .running, items: (0 ..< 20).map {
            .task(TaskRowModel(id: "running-\($0)", backend: "codex", title: "Running task \($0)", status: .running, repoName: "fixture", ageText: "1m"))
        }), .init(bucket: .today, items: (0 ..< 30).map {
            .task(TaskRowModel(id: "recent-\($0)", backend: "codex", title: "Recent task \($0)", status: .completed, repoName: "fixture", ageText: "1h"))
        })]
        let host = NSHostingView(rootView: NavigationSplitView {
            SidebarView(vm).navigationSplitViewColumnWidth(min: 240, ideal: 264, max: 340)
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
            for size in [NSSize(width: 1000, height: 620), NSSize(width: 1280, height: 800)] {
                window.setContentSize(size)
                await waitUntil {
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                    host.layoutSubtreeIfNeeded()
                    return descendants(host).compactMap { $0 as? NSOutlineView }.count == 2
                        && descendants(host).compactMap { $0 as? NSOutlineView }.allSatisfy { $0.numberOfRows > 0 }
                }
                let fields = descendants(host).compactMap { $0 as? NSTextField }
                #expect(!fields.contains { $0.placeholderString == "Search loaded history" })
                let outlines = descendants(host).compactMap { $0 as? NSOutlineView }
                #expect(outlines.count == 2)
                let scrolls = try outlines.map { try #require($0.enclosingScrollView) }
                #expect(scrolls[0] !== scrolls[1])
                let frames = scrolls.map { $0.convert($0.bounds, to: nil) }
                #expect(frames.allSatisfy { $0.maxY <= window.contentLayoutRect.maxY && $0.height > 0 })
                #expect(!frames[0].intersects(frames[1]), "Running and Recent work own disjoint scroll viewports")
                #expect(outlines.allSatisfy { $0.accessibilityRole() == .outline })
                let running = try #require(sidebarFixtureOutline(in: host, role: .running)?.enclosingScrollView)
                let recent = try #require(sidebarFixtureOutline(in: host)?.enclosingScrollView)
                let runningOrigin = running.contentView.bounds.origin
                recent.contentView.scroll(to: CGPoint(x: 0, y: 80))
                recent.reflectScrolledClipView(recent.contentView)
                #expect(running.contentView.bounds.origin == runningOrigin)
                #expect(recent.contentView.bounds.origin.y == 80)
                if let directory = ProcessInfo.processInfo.environment["HARFLOW_M04_SIDEBAR_CAPTURE_DIR"] {
                    let url = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: url.appendingPathComponent("sidebar-\(appearance.rawValue)-\(Int(size.width))x\(Int(size.height)).png"))
                }
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

private struct LayoutHiddenTitle: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar(removing: .title)
    }
}
