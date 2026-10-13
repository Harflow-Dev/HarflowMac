import AppKit
@testable import MainWindowFeature
import PbCommon
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

/// Regression coverage for issue #38. The first test protects the guarded boundary where a
/// backgroundStyle callback during an AppKit native operation must not rewrite the SwiftUI root.
@MainActor @Suite(.serialized) struct SidebarNativeProminenceLayoutTests {
    @Test func givenCellProminenceChangesDuringNativeOperation_whenCallbackRuns_thenRootWriteIsDeferred() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let cell = try #require(fixture.cell)
        await fixture.waitUntilSettled()
        let before = fixture.coordinator.rootWriteCount

        fixture.coordinator.beginNativeOperation()
        cell.backgroundStyle = .emphasized
        #expect(fixture.coordinator.rootWriteCount == before,
                "A native background-style callback must not synchronously rewrite the SwiftUI root")
        fixture.coordinator.endNativeOperation(flushHostedHeights: false)
    }

    @Test func givenNestedNativeOperations_whenProminenceChangesRepeatedly_thenOneQueuedRefreshUsesFinalStyle() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let cell = try #require(fixture.cell)
        await fixture.waitUntilSettled()
        let before = fixture.coordinator.rootWriteCount

        fixture.coordinator.beginNativeOperation()
        fixture.coordinator.beginNativeOperation()
        cell.backgroundStyle = .emphasized
        #expect(fixture.coordinator.rootWriteCount == before)
        fixture.coordinator.endNativeOperation(flushHostedHeights: false)
        await waitUntil(timeout: 2) { !fixture.coordinator.prominenceRefreshQueued }
        #expect(fixture.coordinator.rootWriteCount == before)
        fixture.coordinator.selection = fixture.entry.destination
        fixture.coordinator.endNativeOperation(flushHostedHeights: false)
        #expect(fixture.coordinator.rootWriteCount == before)

        await waitUntil(timeout: 2) {
            !fixture.coordinator.prominenceRefreshQueued
                && fixture.coordinator.pendingProminenceRefreshes.isEmpty
        }
        #expect(fixture.coordinator.rootWriteCount == before + 1)
        #expect(cell.host?.rootView.selected == true,
                "Deferred delivery must use the latest selection value")
        #expect(cell.host?.rootView.increasedProminence == true)
    }

    @Test func givenQueuedProminenceRefresh_whenCellIsDisassociated_thenStaleDeliveryDoesNotRewriteReusedRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let cell = try #require(fixture.cell)
        await fixture.waitUntilSettled()

        fixture.coordinator.beginNativeOperation()
        cell.backgroundStyle = .emphasized
        fixture.coordinator.disassociate(fixture.box)
        fixture.coordinator.endNativeOperation(flushHostedHeights: false)
        let replacement = SidebarNativeItemBox(fixture.entry)
        fixture.coordinator.boxes = [replacement]
        fixture.coordinator.boxesByID[fixture.entry.displayID] = replacement
        fixture.coordinator.indexesByID[fixture.entry.displayID] = 0
        let beforeReplacementDelivery = fixture.coordinator.rootWriteCount
        _ = fixture.coordinator.cell(for: replacement, outline: fixture.outline)
        #expect(fixture.coordinator.rootWriteCount == beforeReplacementDelivery + 1)
        await waitUntil(timeout: 2) {
            !fixture.coordinator.prominenceRefreshQueued
                && fixture.coordinator.pendingProminenceRefreshes.isEmpty
        }
        await Task.yield()

        #expect(fixture.coordinator.rootWriteCount == beforeReplacementDelivery + 1,
                "A stale callback for the old association must not refresh a replacement cell")
    }

    @Test func givenQueuedProminenceRefresh_whenCoordinatorStops_thenStaleDeliveryIsDropped() async throws {
        let fixture = try Fixture()
        let cell = try #require(fixture.cell)
        await fixture.waitUntilSettled()
        let before = fixture.coordinator.rootWriteCount

        fixture.coordinator.beginNativeOperation()
        cell.backgroundStyle = .emphasized
        let staleGeneration = fixture.coordinator.prominenceDeliveryGeneration
        fixture.coordinator.stop()
        fixture.coordinator.endNativeOperation(flushHostedHeights: false)
        fixture.coordinator.deliverProminenceRefresh(generation: staleGeneration)

        #expect(fixture.coordinator.rootWriteCount == before)
        #expect(!fixture.coordinator.prominenceRefreshQueued)
        fixture.close()
    }
}

@MainActor private final class Fixture {
    let coordinator = SidebarNativeList.Coordinator()
    let window: NSWindow
    let outline: SidebarOwnedOutlineView
    let box: SidebarNativeItemBox
    let entry: SidebarListEntry
    var cell: SidebarNativeCell?

    init() throws {
        _ = NSApplication.shared
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        self.outline = SidebarOwnedOutlineView(frame: scroll.bounds)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Prominence"))
        column.width = 320
        outline.addTableColumn(column)
        scroll.documentView = outline
        self.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFrontRegardless()
        try #require(outline.window === window)
        coordinator.install(scroll: scroll, outline: outline)
        coordinator.environment = EnvironmentValues()
        self.entry = SidebarListEntry(id: "task:prominence", content: .item(.task(TaskRowModel(
            id: "prominence", backend: "codex", title: "Prominence", status: .completed,
            repoName: "repo", ageText: "1m"))))
        self.box = SidebarNativeItemBox(entry)
        coordinator.boxes = [box]
        coordinator.boxesByID[entry.displayID] = box
        coordinator.indexesByID[entry.displayID] = 0
        self.cell = coordinator.cell(for: box, outline: outline)
        if let cell { outline.addSubview(cell) }
        try #require(cell?.window === window)
    }

    func waitUntilSettled() async {
        await waitUntil(timeout: 2) {
            self.coordinator.knownWidth == self.coordinator.availableWidth
                && !self.coordinator.widthInvalidationQueued
                && !self.coordinator.deliveryQueued
                && !self.coordinator.prominenceRefreshQueued
                && self.coordinator.pendingHeights.isEmpty
                && self.coordinator.pendingMounted.isEmpty
        }
        await Task.yield()
    }

    func close() {
        coordinator.stop()
        window.contentView = nil
        window.close()
    }
}
