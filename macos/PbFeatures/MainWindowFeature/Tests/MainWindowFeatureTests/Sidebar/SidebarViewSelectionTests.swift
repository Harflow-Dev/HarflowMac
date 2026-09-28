//
//  SidebarViewSelectionTests.swift
//  MainWindowFeatureTests
//
//  The sidebar `List(selection:)` only lets a row be selected when the row's tag has exactly the
//  selection manager's value type, `MonitorDestination`. A row tagged `MonitorDestination?` renders
//  fine but can never be selected — by click or by arrow key — so this hosts the real `SidebarView`
//  and asks the backing outline view directly, rather than trusting that the tags "look right".
//

import AppKit
@testable import MainWindowFeature
@testable import MonitorCore
import PbCommon
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

@MainActor
@Suite struct SidebarViewSelectionTests {

    // MARK: - Helpers

    private func makeSUT() async -> (vm: SidebarViewModelMock, outline: NSOutlineView, window: NSWindow)? {
        let vm = SidebarViewModelMock(parallelGroups: [ParallelGroup(name: "release", members: [], conversations: [])])
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 280, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: SidebarView(vm).frame(width: 280, height: 800))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let findOutline = { Self.allSubviews(host).compactMap { $0 as? NSOutlineView }.first }
        await waitUntil { (findOutline()?.numberOfRows ?? 0) > 0 }
        guard let outline = findOutline() else { return nil }
        return (vm, outline, window)
    }

    private static func allSubviews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allSubviews)
    }

    /// Rows the delegate allows selecting, selected one at a time, with the destination each
    /// selection wrote back through the binding.
    private func selectEverySelectableRow(_ sut: (vm: SidebarViewModelMock, outline: NSOutlineView, window: NSWindow)) async -> [MonitorDestination] {
        var selected: [MonitorDestination] = []
        for row in 0 ..< sut.outline.numberOfRows {
            let item = sut.outline.item(atRow: row) as Any
            guard sut.outline.delegate?.outlineView?(sut.outline, shouldSelectItem: item) == true else { continue }
            let previous = sut.vm.selection
            sut.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            await waitUntil { sut.vm.selection != previous }
            if let destination = sut.vm.selection, destination != previous { selected.append(destination) }
        }
        return selected
    }

    // MARK: - Selection

    @Test func givenTheSidebar_whenEachRowIsSelected_thenEveryTaskAndGroupRowReachesTheBinding() async throws {
        // given
        let sut = try #require(await makeSUT())

        // when
        let selected = await selectEverySelectableRow(sut)

        // then — the mock's default running tree ("abc123" expanded, with its child
        // "abc123-child" visible), the group, and the recent row ("def456"), in sidebar order.
        // Monitor piece 4: the tree's guide gutter and disclosure chevron must not make the
        // expanded child row itself unselectable.
        #expect(selected == [.task("abc123"), .task("abc123-child"), .group("release"), .task("def456")])
    }
}
