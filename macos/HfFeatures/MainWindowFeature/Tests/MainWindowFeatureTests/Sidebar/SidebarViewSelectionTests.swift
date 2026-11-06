//
//  SidebarViewSelectionTests.swift
//  MainWindowFeatureTests
//
//  The sidebar's real observation surface is exactly one unified native outline — navigation and
//  Running/Recent scrolled content together — so tag wiring can never just "look right". This
//  hosts the real `SidebarView`, locates that outline through the production `navigation:new-task`
//  identity (which also exists while loading, when no work headings exist yet), and drives AppKit's
//  own selection: the delegate's `shouldSelectItem` decides what is selectable, `selectRowIndexes`
//  drives the production binding. New task stays the composer request — a command counted through
//  its routed state, never a destination selection.
//

import AppKit
import HfCommon
import HfTestUtilities
@testable import MainWindowFeature
import SwiftUI
import Testing

@MainActor
@Suite struct SidebarViewSelectionTests {

    // MARK: - Helpers

    private func makeSUT(skeleton: Bool = false) async -> (vm: SidebarViewModelMock, host: NSHostingView<AnyView>,
                                                           outline: NSOutlineView, window: NSWindow)? {
        let vm = SidebarViewModelMock(showsLoadingSkeleton: skeleton)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 280, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(SidebarView(vm).frame(width: 280, height: 800)))
        window.contentView = host
        await waitUntil(timeout: 5) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            host.layoutSubtreeIfNeeded()
            guard let outline = unifiedOutline(in: host) else { return false }
            return outline.numberOfRows > 0
        }
        guard let outline = unifiedOutline(in: host) else { return nil }
        return (vm, host, outline, window)
    }

    private func allSubviews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allSubviews)
    }

    /// The unified production surface, located by the navigation identity the design guarantees at
    /// its top — never by a headings-only lookup, so the loading surface is found identically.
    private func unifiedOutline(in view: NSView) -> NSOutlineView? {
        allSubviews(view).compactMap { $0 as? NSOutlineView }.first { outline in
            (0 ..< outline.numberOfRows).contains {
                (outline.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id == "navigation:new-task"
            }
        }
    }

    private func entry(at row: Int, in outline: NSOutlineView) -> SidebarListEntry? {
        (outline.item(atRow: row) as? SidebarNativeItemBox)?.entry
    }

    private func entryContent(at row: Int, in outline: NSOutlineView) -> SidebarListEntry.Content? {
        entry(at: row, in: outline)?.content
    }

    /// Only real work rows and the navigation rows carry a destination; the entry inventory decides
    /// which is which, and the delegate census below holds the two sides exactly equal.
    private func isSelectableEntry(_ entry: SidebarListEntry?) -> Bool {
        guard let entry else { return false }
        switch entry.content {
        case .navigation, .item: return true
        default: return false
        }
    }

    private func waitForWorkRows(in outline: NSOutlineView) async {
        let expected: Set = ["task:abc123", "task:abc123-child", "task:def456", "task:ghi789"]
        await waitUntil(timeout: 5) {
            let ids = Set((0 ..< outline.numberOfRows).compactMap {
                (outline.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id
            })
            return expected.isSubset(of: ids)
        }
    }

    // MARK: - Unified surface

    @Test func givenTheSidebar_whenHosted_thenExactlyOneUnifiedOutlineAndScrollerExist() async throws {
        // given
        let sut = try #require(await makeSUT())
        defer { sut.window.contentView = nil; sut.window.close() }
        // when
        let outlines = allSubviews(sut.host).compactMap { $0 as? NSOutlineView }
        let scrollers = allSubviews(sut.host).compactMap { $0 as? NSScrollView }.filter { $0.documentView is NSOutlineView }
        // then — the redesigned sidebar is strictly one native outline in one owned scroller.
        #expect(outlines.count == 1)
        #expect(outlines.first === sut.outline)
        #expect(scrollers.count == 1)
        #expect(scrollers.first === sut.outline.enclosingScrollView)
    }

    @Test func givenLoadingSidebar_whenWorkHasNotArrived_thenNavigationStillLocatesTheUnifiedOutline() async throws {
        // given — no listing has arrived, so the unified surface shows no work headings yet.
        let sut = try #require(await makeSUT(skeleton: true))
        defer { sut.window.contentView = nil; sut.window.close() }
        // when
        let outlines = allSubviews(sut.host).compactMap { $0 as? NSOutlineView }
        let ids = (0 ..< sut.outline.numberOfRows).compactMap { entry(at: $0, in: sut.outline)?.id }
        // then — the production navigation identity locates the one outline without any heading.
        #expect(outlines.count == 1)
        #expect(outlines.first === sut.outline)
        #expect(ids.contains("navigation:new-task"))
        #expect(ids.contains("diagnostic:skeleton"))
        #expect(!ids.contains { $0.hasPrefix("header:") })
    }

    // MARK: - Selection

    @Test func givenTheSidebar_whenEachWorkRowIsSelected_thenEveryTaskAndGroupRowReachesTheBinding() async throws {
        // given
        let sut = try #require(await makeSUT())
        defer { sut.window.contentView = nil; sut.window.close() }
        let outline = sut.outline
        let vm = sut.vm
        await waitForWorkRows(in: outline)

        // when — the work inventory comes from the reconciled entries: every row whose content is a
        // real work item, in document order. The delegate decides selectability and native index
        // selection drives the production binding; no VM or coordinator callback is driven directly.
        var selected: [MonitorDestination] = []
        for row in 0 ..< outline.numberOfRows {
            guard let content = entryContent(at: row, in: outline), case .item = content else { continue }
            let item = outline.item(atRow: row)
            #expect(outline.delegate?.outlineView?(outline, shouldSelectItem: item) == true,
                     "Work row \(row) must be delegated-selectable")
            let previous = vm.selection
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            await waitUntil(timeout: 5) { vm.selection != previous }
            if let destination = vm.selection, destination != previous { selected.append(destination) }
        }

        // then — the mock's default sections: the running tree ("abc123" expanded, with its child
        // "abc123-child" visible), the inline parallel group, then the Today and Earlier rows.
        // Monitor piece 4: the tree's guide gutter and disclosure chevron must not make the
        // expanded child row itself unselectable.
        #expect(selected == [
            .task("abc123"), .task("abc123-child"), .group("review-bot"), .task("def456"), .task("ghi789")
        ])

        // then — no selectable row was silently excluded: the native delegate admits exactly the
        // navigation rows (covered by their own test) and these work rows, and nothing else.
        for row in 0 ..< outline.numberOfRows {
            let item = outline.item(atRow: row)
            let selectable = outline.delegate?.outlineView?(outline, shouldSelectItem: item) == true
            #expect(selectable == isSelectableEntry(entry(at: row, in: outline)))
        }
    }

    @Test func givenTheSidebar_whenNavigationRowsAreSelected_thenEachRoutesItsOwnDestinationThroughTheNativePath() async throws {
        // given
        let sut = try #require(await makeSUT())
        defer { sut.window.contentView = nil; sut.window.close() }
        let outline = sut.outline
        let vm = sut.vm
        await waitForWorkRows(in: outline)

        // when — read the production navigation block in document order.
        var rows: [Int] = []
        var destinations: [MonitorDestination] = []
        for row in 0 ..< outline.numberOfRows {
            guard let entry = entry(at: row, in: outline), case .navigation = entry.content else { continue }
            rows.append(row)
            if let destination = entry.destination { destinations.append(destination) }
        }
        // then — the five approved M04 navigation rows, each with its real destination.
        #expect(rows.count == 5)
        #expect(destinations == [.newSession, .needsYou(itemID: nil), .workflowLibrary, .resourceSlots, .statistics])

        // when — select each through AppKit's own selection.
        for (row, destination) in zip(rows, destinations) {
            if destination == .newSession {
                // New task is the composer request, a command: wait for its routed state, never a
                // VM selection change, because it can never become `selection`.
                let commandsBefore = vm.newSessionTapCount
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                await waitUntil(timeout: 5) { vm.newSessionTapCount == commandsBefore + 1 }
                #expect(vm.newSessionTapCount == commandsBefore + 1)
                #expect(vm.selection == nil)
            } else {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                await waitUntil(timeout: 5) { vm.selection == destination }
                #expect(vm.selection == destination)
            }
        }

        // then — one traversal of the navigation block dispatched the composer request exactly once.
        #expect(vm.newSessionTapCount == 1)
    }
}
