//
//  SidebarWindowLayoutTests.swift
//  MainWindowFeatureTests
//
//  The M04 window layout contract (`.hd-m04-sidebar-scroll`): navigation, Running and Recent work
//  scroll as ONE native outline in ONE owned scroller, contained below the fixed brand header and
//  above the fixed appearance/Settings footer, at both windowed sizes and in both appearances. One
//  legal 80pt scroll must move nav, Running and Recent row geometry together while the fixed chrome
//  and the scroller frame stay put.
//

import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct SidebarWindowLayoutTests {

    private static let requiredIDs: Set<String> = [
        "navigation:new-task", "navigation:needs-you", "navigation:workflows", "navigation:resources",
        "navigation:statistics", "navigation:pending-launches", "header:running", "header:recent", "history:sentinel",
        "task:running-0", "task:running-19", "task:recent-0", "task:recent-29"
    ]

    private static let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")

    @Test func givenM04UnifiedSidebar_whenWindowedResizedAndScrolled_thenOneOutlineScrollsTogetherUnderFixedChrome() async throws {
        // given
        _ = NSApplication.shared
        let vm = SidebarViewModelMock()
        vm.sections = Self.scrollingSections()
        // The fixed chrome's frames are read from the hosted accessibility tree, which only exists
        // once this test process presents itself as an enhanced accessibility client.
        let previousAX = NSApplication.shared.accessibilityAttributeValue(Self.enhancedUI)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: Self.enhancedUI)
        defer { NSApplication.shared.accessibilitySetValue(previousAX, forAttribute: Self.enhancedUI) }
        let host = NSHostingView(rootView: NavigationSplitView {
            SidebarView(vm).navigationSplitViewColumnWidth(min: 240, ideal: 264, max: 340)
        } detail: { Text("Detail") }
            .frame(minWidth: 1000, minHeight: 620)
.modifier(LayoutHiddenTitle())
.withPresentationContext())
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
                let outline = try await appliedUnifiedOutline(host: host, window: window, appearance: appearance)
                let scroll = try #require(outline.enclosingScrollView)
                assertOneUnifiedSurface(host: host, outline: outline, scroll: scroll)
                assertUnifiedContent(host: host, outline: outline)
                assertRowGeometry(outline: outline)
                let chrome = try fixedChrome(host: host, window: window, scroll: scroll)
                try assertScrolledRowsTranslateTogether(outline: outline, scroll: scroll)
                try assertFixedChromeDidNotMove(host: host, window: window, scroll: scroll, chrome: chrome)
                try captureEvidence(host: host, appearance: appearance, size: size)
            }
        }
    }

    // MARK: - Applied presentation

    /// Readiness is the actually applied presentation in the actual window — the real frame, the
    /// effective appearance and a fully settled reconciliation — never one of the geometry facts the
    /// test is about to assert.
    private func appliedUnifiedOutline(host: NSView, window: NSWindow, appearance: NSAppearance.Name) async throws -> NSOutlineView {
        await waitUntil(timeout: 5) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            host.layoutSubtreeIfNeeded()
            guard window.effectiveAppearance.name == appearance,
                  host.bounds.size == window.frame.size,
                  let outline = unifiedOutline(in: host),
                  let coordinator = outline.delegate as? SidebarNativeList.Coordinator
            else { return false }
            let ids = Set((0 ..< outline.numberOfRows).compactMap {
                (outline.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id
            })
            return outline.numberOfRows > 0
                && Self.requiredIDs.isSubset(of: ids)
                && coordinator.reconciliation == nil
                && coordinator.detached == nil
                && coordinator.pendingInput == nil
                && !coordinator.hasUnsettledPresentations
                && coordinator.pendingHostedHeights.isEmpty
                && coordinator.pendingHeights.isEmpty
                && outline.rect(ofRow: outline.numberOfRows - 1).height > 0
        }
        return try #require(unifiedOutline(in: host))
    }

    // MARK: - Unified surface assertions

    private func assertOneUnifiedSurface(host: NSView, outline: NSOutlineView, scroll: NSScrollView) {
        // Then — the unified surface is one native outline in one owned scroller: no second viewport
        // with an independent origin anywhere in the windowed layout.
        let outlines = allSubviews(host).compactMap { $0 as? NSOutlineView }
        #expect(outlines.count == 1)
        #expect(outline.accessibilityRole() == .outline)
        let outlineScrollers = allSubviews(host).compactMap { $0 as? NSScrollView }.filter { $0.documentView is NSOutlineView }
        #expect(outlineScrollers.count == 1)
        #expect(outlineScrollers.first === scroll)
        #expect(scroll.documentView === outline)
        #expect(scroll.scrollerStyle == .overlay)
        #expect(scroll.verticalScroller?.controlSize == .small)
        #expect(scroll.hasVerticalScroller && !scroll.hasHorizontalScroller)
        #expect(scroll.autohidesScrollers)
        #expect(scroll.contentInsets.top == 0 && scroll.contentInsets.left == 0
            && scroll.contentInsets.bottom == 0 && scroll.contentInsets.right == 0)
    }

    private func assertUnifiedContent(host: NSView, outline: NSOutlineView) {
        // Then — search is gone, and the one outline carries the complete nav, Running and Recent
        // work identity set, reconciled in that order.
        let fields = allSubviews(host).compactMap { $0 as? NSTextField }
        #expect(!fields.contains { $0.placeholderString == "Search loaded history" })
        var navRowCount = 0
        var workRowCount = 0
        var ids = Set<String>()
        for row in 0 ..< outline.numberOfRows {
            guard let box = outline.item(atRow: row) as? SidebarNativeItemBox else { continue }
            ids.insert(box.entry.id)
            if box.entry.id.hasPrefix("navigation:") { navRowCount += 1 }
            if case .item = box.entry.content { workRowCount += 1 }
        }
        #expect(Self.requiredIDs.isSubset(of: ids))
        #expect(navRowCount == 6)
        #expect(workRowCount == 50)
    }

    private func assertRowGeometry(outline: NSOutlineView) {
        // Then — normal row geometry: navigation rows hold their 32pt height when the ambient
        // minimum allows, and no realized row is ever compressed below its fitting height.
        for row in 0 ..< outline.numberOfRows {
            guard let box = outline.item(atRow: row) as? SidebarNativeItemBox else { continue }
            if case .navigation = box.entry.content, box.entry.minimumHeight <= 32 {
                #expect(abs(outline.rect(ofRow: row).height - 32) <= 1)
            }
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarNativeCell,
                  let cellHost = cell.host, cellHost.fittingSize.height > 0
            else { continue }
            #expect(outline.rect(ofRow: row).height >= cellHost.fittingSize.height - 1)
        }
    }

    // MARK: - Fixed chrome and scrolling

    /// The fixed header and footer frames plus the scroller's viewport frame, all in window
    /// coordinates, with the one viewport's containment below the header, above the footer and
    /// inside the window's content layout.
    private func fixedChrome(host: NSView, window: NSWindow, scroll: NSScrollView)
        throws -> (headerFrame: CGRect, footerFrame: CGRect, viewportFrame: CGRect) {
        let header = try #require(element(labelled: "Collapse sidebar", in: host))
        let footer = try #require(element(labelled: "Settings", in: host))
        let headerFrame = try #require(frame(of: header, in: window))
        let footerFrame = try #require(frame(of: footer, in: window))
        let viewportFrame = scroll.convert(scroll.bounds, to: nil)
        #expect(viewportFrame.height > 0)
        #expect(viewportFrame.maxY <= window.contentLayoutRect.maxY, "Viewport stays inside the window content")
        #expect(viewportFrame.maxY <= headerFrame.minY + 1, "Viewport stays below the fixed header")
        #expect(viewportFrame.minY >= footerFrame.maxY - 1, "Viewport stays above the fixed footer")
        return (headerFrame, footerFrame, viewportFrame)
    }

    private func assertScrolledRowsTranslateTogether(outline: NSOutlineView, scroll: NSScrollView) throws {
        let clip = scroll.contentView
        // given — the unified document is one piece of scrollable content running from the
        // navigation through to the bottom sentinel, taller than one viewport by far more than the
        // 80pt scroll about to be made.
        let document = try #require(scroll.documentView)
        #expect(document.bounds.height > clip.bounds.height + 80)
        let tracked = ["navigation:new-task", "task:running-0", "header:recent", "task:recent-29"]
        let windowFrameOf: (String) -> CGRect? = { id in
            let row = (0 ..< outline.numberOfRows).first(where: {
                (outline.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id == id
            })
            // The native outline reports row rects even while the row is scrolled offscreen.
            guard let row else { return nil }
            return outline.convert(outline.rect(ofRow: row), to: nil)
        }
        let rowsBefore = tracked.compactMap { windowFrameOf($0) }
        #expect(rowsBefore.count == tracked.count)
        let originBefore = clip.bounds.origin

        // when — one legal 80pt scroll, constrained first so the whole shift fits.
        let proposed = NSRect(origin: CGPoint(x: originBefore.x, y: originBefore.y + 80), size: clip.bounds.size)
        let constrained = clip.constrainBoundsRect(proposed)
        #expect(abs(constrained.minY - (originBefore.y + 80)) <= 1, "The 80pt scroll is legal")
        clip.scroll(to: constrained.origin)
        scroll.reflectScrolledClipView(clip)
        #expect(abs(clip.bounds.minY - (originBefore.y + 80)) <= 1)

        // then — nav, Running and Recent row geometry translated together, by one shared actual
        // 80pt shift: no viewport owns an independent origin.
        let rowsAfter = tracked.compactMap { windowFrameOf($0) }
        #expect(rowsAfter.count == rowsBefore.count)
        let deltas = zip(rowsBefore, rowsAfter).map { before, after in
            CGPoint(x: after.minX - before.minX, y: after.minY - before.minY)
        }
        let shared = try #require(deltas.first, "Tracked nav, Running and Recent rows must be measurable")
        #expect(deltas.allSatisfy { abs($0.y - shared.y) <= 1 && abs($0.x) <= 1 })
        #expect(abs(shared.y) >= 79 && abs(shared.y) <= 81, "The shared shift is the actual 80pt scroll")
    }

    private func assertFixedChromeDidNotMove(host: NSView, window: NSWindow, scroll: NSScrollView,
                                             chrome: (headerFrame: CGRect, footerFrame: CGRect, viewportFrame: CGRect)) throws {
        // Then — the fixed header and footer accessibility frames and the scroller frame did not
        // move with the content.
        let header = try #require(element(labelled: "Collapse sidebar", in: host))
        let footer = try #require(element(labelled: "Settings", in: host))
        let headerAfter = try #require(frame(of: header, in: window))
        let footerAfter = try #require(frame(of: footer, in: window))
        #expect(abs(headerAfter.minY - chrome.headerFrame.minY) <= 1
            && abs(headerAfter.maxY - chrome.headerFrame.maxY) <= 1)
        #expect(abs(footerAfter.minY - chrome.footerFrame.minY) <= 1
            && abs(footerAfter.maxY - chrome.footerFrame.maxY) <= 1)
        let viewportAfter = scroll.convert(scroll.bounds, to: nil)
        #expect(abs(viewportAfter.minY - chrome.viewportFrame.minY) <= 1)
        #expect(abs(viewportAfter.maxY - chrome.viewportFrame.maxY) <= 1)
    }

    private func captureEvidence(host: NSView, appearance: NSAppearance.Name, size: NSSize) throws {
        guard let directory = ProcessInfo.processInfo.environment["HARFLOW_M04_SIDEBAR_CAPTURE_DIR"] else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url.appendingPathComponent("sidebar-\(appearance.rawValue)-\(Int(size.width))x\(Int(size.height)).png"))
    }

    // MARK: - Fixtures and helpers

    private static func scrollingSections() -> [SidebarSection] {
        [
            .init(bucket: .running, items: (0 ..< 20).map {
                .task(TaskRowModel(id: "running-\($0)", backend: "codex", title: "Running task \($0)", status: .running, repoName: "fixture", ageText: "1m"))
            }),
            .init(bucket: .today, items: (0 ..< 30).map {
                .task(TaskRowModel(id: "recent-\($0)", backend: "codex", title: "Recent task \($0)", status: .completed, repoName: "fixture", ageText: "1h"))
            })
        ]
    }

    private func allSubviews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allSubviews)
    }

    /// The unified production surface, located by the production navigation identity — never by a
    /// headings-only lookup — with no assumption about subview order.
    private func unifiedOutline(in view: NSView) -> NSOutlineView? {
        allSubviews(view).compactMap { $0 as? NSOutlineView }.first { outline in
            (0 ..< outline.numberOfRows).contains {
                (outline.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id == "navigation:new-task"
            }
        }
    }

    /// The hosted accessibility tree: the AppKit subviews plus the platform elements SwiftUI exposes
    /// through `accessibilityChildren`, recursively.
    private func accessibilityElements(in view: NSView) -> [NSObject] {
        var found: [NSObject] = []
        for subview in view.subviews { found += accessibilityElements(in: subview) }
        found += accessibilityTree(view)
        return found
    }

    private func accessibilityTree(_ element: NSObject) -> [NSObject] {
        var result = [element]
        let children = NSSelectorFromString("accessibilityChildren")
        guard element.responds(to: children),
              let raw = element.perform(children)?.takeUnretainedValue() as? [Any]
        else { return result }
        for child in raw {
            if let object = child as? NSObject { result += accessibilityTree(object) }
        }
        return result
    }

    private func accessibilityString(_ element: NSObject, _ name: String) -> String? {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue() as? String
    }

    private func element(labelled label: String, in host: NSView) -> NSObject? {
        accessibilityElements(in: host).first {
            accessibilityString($0, "accessibilityLabel") == label
                || accessibilityString($0, "accessibilityTitle") == label
                || accessibilityString($0, "accessibilityValue") == label
        }
    }

    /// The element's frame in window coordinates (accessibility frames are screen coordinates).
    private func frame(of element: NSObject, in window: NSWindow) -> CGRect? {
        if let accessible = element as? any NSAccessibilityProtocol {
            return window.convertFromScreen(accessible.accessibilityFrame())
        }
        guard element.responds(to: NSSelectorFromString("accessibilityFrame")),
              let value = element.value(forKey: "accessibilityFrame") as? NSValue
        else { return nil }
        return window.convertFromScreen(value.rectValue)
    }
}

private struct LayoutHiddenTitle: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar(removing: .title)
    }
}
