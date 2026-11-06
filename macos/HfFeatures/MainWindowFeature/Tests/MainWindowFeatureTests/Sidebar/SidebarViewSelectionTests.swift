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
import HfCommon
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
@testable import MonitorCore
import SwiftUI
import Testing

@MainActor
@Suite struct SidebarViewSelectionTests {

    // MARK: - Helpers

    private func makeSUT() async -> (vm: SidebarViewModelMock, outlines: [NSOutlineView], window: NSWindow)? {
        let vm = SidebarViewModelMock()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 280, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: SidebarView(vm).frame(width: 280, height: 800))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let findOutline = { sidebarFixtureOutline(in: host) }
        await waitUntil { (findOutline()?.numberOfRows ?? 0) > 0 }
        guard let recent = findOutline(), let running = sidebarFixtureOutline(in: host, role: .running) else { return nil }
        return (vm, [running, recent], window)
    }

    private static func allSubviews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allSubviews)
    }

    /// Rows the delegate allows selecting, selected one at a time, with the destination each
    /// selection wrote back through the binding.
    private func selectEverySelectableRow(_ sut: (vm: SidebarViewModelMock, outlines: [NSOutlineView], window: NSWindow)) async -> [MonitorDestination] {
        var selected: [MonitorDestination] = []
        for outline in sut.outlines {
        for row in 0 ..< outline.numberOfRows {
            let item = outline.item(atRow: row) as Any
            guard outline.delegate?.outlineView?(outline, shouldSelectItem: item) == true else { continue }
            let previous = sut.vm.selection
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            await waitUntil { sut.vm.selection != previous }
            if let destination = sut.vm.selection, destination != previous { selected.append(destination) }
        }
        }
        return selected
    }

    // MARK: - Selection

    @Test func givenTheSidebar_whenEachRowIsSelected_thenEveryTaskAndGroupRowReachesTheBinding() async throws {
        // given
        let sut = try #require(await makeSUT())

        // when
        let selected = await selectEverySelectableRow(sut)

        // then — the mock's default sections: the running tree ("abc123" expanded, with its child
        // "abc123-child" visible), the inline parallel group, then the Today and Earlier rows.
        // Monitor piece 4: the tree's guide gutter and disclosure chevron must not make the
        // expanded child row itself unselectable.
        #expect(selected == [
            .task("abc123"), .task("abc123-child"), .group("review-bot"), .task("def456"), .task("ghi789")
        ])
    }
}
