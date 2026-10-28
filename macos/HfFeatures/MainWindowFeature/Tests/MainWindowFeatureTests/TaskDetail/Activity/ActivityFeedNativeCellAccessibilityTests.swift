import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct ActivityFeedNativeCellAccessibilityTests {
    @Test func givenNativeCell_whenTailRecyclesThroughHiddenSentinel_thenRoleAndBoundaryMatchCurrentContent() throws {
        let cell = ActivityFeedNativeCell(frame: CGRect(x: 0, y: 0, width: 403, height: 100))
        let actions = ActivityFeedNativeActions()
        let tail = ActivityFeedNativeEntry.tail(.plainText("Actual SwiftUI tail content"), topSpacing: 12)
        cell.configure(root: root(tail, actions: actions), id: tail.id)
        let firstHost = try #require(cell.host)
        #expect(cell.isAccessibilityElement())
        #expect(cell.accessibilityRole() == .cell)

        let bottom = ActivityFeedNativeEntry.bottom(topSpacing: 20)
        cell.configure(root: root(bottom, actions: actions), id: bottom.id)
        #expect(!cell.isAccessibilityElement())
        #expect(cell.accessibilityChildren()?.isEmpty == true)
        #expect(firstHost.superview == nil)

        cell.configure(root: root(tail, actions: actions), id: tail.id)
        let recycledHost = try #require(cell.host)
        #expect(recycledHost !== firstHost)
        #expect(recycledHost.superview === cell)
        #expect(cell.isAccessibilityElement())
        #expect(cell.accessibilityRole() == .cell)
        // Actual SwiftUI text/button descendants require the external AX application fixture.
    }

    @Test func givenOwnedTable_whenTailIsRealized_thenCustomNativeRowViewIsInstalled() async throws {
        _ = NSApplication.shared
        let state = ParallelColumnUIState()
        let pending = PendingMessage(id: "native-row", text: "Real native row fixture")
        let host = NSHostingView(rootView: ActivityFeedView(rows: [], start: nil, history: EventHistoryState(), isLoading: false,
            tailValue: ActivityFeedTail(pendingMessages: [pending]), state: state, onLoadMore: nil,
            tailPresentation: .plainText(pending.text)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 3) { state.viewportPositioned && activityNativeVisibleTail(host) != nil }
        let cell = try #require(activityNativeVisibleTail(host))
        let table = try #require(cell.enclosingScrollView?.documentView as? NSTableView)
        let row = table.row(for: cell)
        #expect(row >= 0)
        #expect(table.rowView(atRow: row, makeIfNecessary: false) is ActivityFeedNativeRowView)
        #expect(cell.accessibilityRole() == .cell)
    }

    @Test func givenRecycledCellWithUnchangedBounds_whenHostingContentIsRecreated_thenHostGeometryIsReadySynchronously() throws {
        // given
        let cell = ActivityFeedNativeCell(frame: CGRect(x: 0, y: 0, width: 403, height: 214))
        let actions = ActivityFeedNativeActions()
        let entry = ActivityFeedNativeEntry.tail(.plainText("Replacement hosted content"), topSpacing: 12)
        cell.configure(root: root(entry, actions: actions), id: entry.id)
        cell.releaseHostedContent()
        let originalBounds = cell.bounds
        // when: native reuse keeps the cell's size, so no autoresizing notification follows.
        cell.configure(root: root(entry, actions: actions), id: entry.id)
        // then: no run-loop yield, layout pass, parent update or synthetic movement is needed.
        let host = try #require(cell.host)
        #expect(cell.bounds == originalBounds)
        #expect(host.frame == originalBounds)
        #expect(host.bounds.size == originalBounds.size)
    }

    private func root(_ entry: ActivityFeedNativeEntry, actions: ActivityFeedNativeActions) -> ActivityFeedNativeRowRoot {
        ActivityFeedNativeRowRoot(entry: entry, start: nil, horizontalPadding: 12, showsPromptBubble: true,
                                  environment: ActivityFeedNativeEnvironment(EnvironmentValues()), actions: actions, availableWidth: 403)
    }
}
