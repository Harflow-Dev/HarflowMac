import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import Testing

@MainActor
@Suite(.serialized)
struct SidebarNativeSelectionHostedTests {
    @Test func givenRealAliasRows_whenNativeSelectionMovesAndDeselects_thenExactlyTheLogicalAliasesAreHighlighted() async throws {
        // given — the production outline owns both physical occurrences of each logical alias.
        let fixture = try await NativeSidebarWindowFixture(aliasFixture: true)
        defer { fixture.close() }
        fixture.model.didToggleExpansion(taskID: "group:g")
        await fixture.model.waitForPresentation()
        await fixture.settle()
        let coordinator = try #require(fixture.outline.delegate as? SidebarNativeList.Coordinator)
        #expect(fixture.outline.style == .sourceList)
        let aliasRows = (0 ..< fixture.outline.numberOfRows).filter {
            let id = (fixture.outline.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id
            return id == "task:g1" || id == "task:g2"
        }
        try #require(aliasRows.count == 4)
        let g1Rows = [aliasRows[0], aliasRows[2]]
        let g2Rows = [aliasRows[1], aliasRows[3]]
        #expect(aliasRows.allSatisfy { row in
            guard let nativeRow = fixture.outline.rowView(atRow: row, makeIfNecessary: true) as? SidebarNativeSelection else {
                return false
            }
            // Raw value 1 is AppKit's legacy source-list highlight style.
            nativeRow.selectionHighlightStyle = .init(rawValue: 1) ?? .regular
            let sourceListAttempt = nativeRow.selectionHighlightStyle == .regular
            nativeRow.selectionHighlightStyle = .none
            return sourceListAttempt && nativeRow.selectionHighlightStyle == .regular
        })

        // when — select the first occurrence through the native outline route.
        fixture.outline.selectRowIndexes(IndexSet(integer: g1Rows[0]), byExtendingSelection: false)
        fixture.layout()
        await waitUntil(timeout: 5) {
            fixture.layout()
            return fixture.outline.selectedRowIndexes == IndexSet(g1Rows)
                && fixture.model.selection == .task("g1")
        }
        #expect(fixture.outline.selectedRowIndexes == IndexSet(g1Rows))
        assertSelected(g1Rows, in: fixture)
        assertUnselected(g2Rows, in: fixture)

        fixture.window.makeFirstResponder(fixture.outline)
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: fixture.window.windowNumber, context: nil,
                                    characters: String(UnicodeScalar(0xF701)!),
                                    charactersIgnoringModifiers: String(UnicodeScalar(0xF701)!),
                                    isARepeat: false, keyCode: 125)
        if let down { fixture.outline.keyDown(with: down) }
        await waitUntil(timeout: 5) {
            fixture.layout()
            return fixture.outline.selectedRowIndexes == IndexSet(g2Rows)
                && fixture.model.selection == .task("g2")
        }
        #expect(fixture.outline.selectedRowIndexes == IndexSet(g2Rows))
        assertSelected(g2Rows, in: fixture)
        assertUnselected(g1Rows, in: fixture)
        #expect(coordinator.destinationIndexes[.task("g2")] == IndexSet(g2Rows))

        // then — deselection clears every alias without leaving an opaque selected surface behind.
        fixture.outline.deselectAll(nil)
        await waitUntil(timeout: 5) {
            fixture.layout()
            return fixture.model.selection == nil && fixture.outline.selectedRowIndexes.isEmpty
        }
        #expect(fixture.outline.selectedRowIndexes.isEmpty)
        #expect(coordinator.lastHostedSelectedIDs.isEmpty)
        assertUnselected(aliasRows, in: fixture)
    }

    private func assertSelected(_ rows: [Int], in fixture: NativeSidebarWindowFixture) {
        #expect(rows.allSatisfy { row in
            guard let cell = fixture.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarNativeCell,
                  let nativeRow = fixture.outline.rowView(atRow: row, makeIfNecessary: true) else { return false }
            return nativeRow.isSelected && nativeRow.interiorBackgroundStyle == .normal
                && cell.host?.rootView.selected == true
        })
    }

    private func assertUnselected(_ rows: [Int], in fixture: NativeSidebarWindowFixture) {
        #expect(rows.allSatisfy { row in
            let cell = fixture.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarNativeCell
            return cell?.host?.rootView.selected == false
        })
    }
}
