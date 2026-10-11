import AppKit
@testable import MainWindowFeature
import PbCommon
import PbUI
import SwiftUI
import Testing

@MainActor
@Suite(.serialized)
struct SidebarNativeMeasurementEnvironmentTests {
    @Test func givenNativeRowEnvironment_whenOwnerChanges_thenResolvedContentInputsFollowCurrentOwner() {
        // given — a real row configuration with an observable view-event owner.
        var firstEvent = ViewEvent.none
        var secondEvent = ViewEvent.none
        let actions = SidebarNativeActions()
        actions.viewEvent = Binding(get: { firstEvent }, set: { firstEvent = $0 })
        let entry = SidebarListEntry(id: "task:environment", content: .item(.task(TaskRowModel(
            id: "environment", backend: "codex", title: "Environment", status: .completed,
            repoName: "repo", ageText: "1m"))))
        let row = SidebarNativeRow(entry: entry, actions: actions, selected: false, animate: false,
                                   environment: EnvironmentValues(), increasedProminence: true,
                                   occupiedHeight: { _ in })

        // when — the actual applied environment is resolved, then the owner changes.
        let firstResolved = row.resolvedEnvironment
        firstResolved.viewEvent.wrappedValue = .incident(source: "first", message: "first")
        actions.viewEvent = Binding(get: { secondEvent }, set: { secondEvent = $0 })
        let secondResolved = row.resolvedEnvironment
        secondResolved.viewEvent.wrappedValue = .incident(source: "second", message: "second")

        // then — prominence is explicit and the forwarding binding reaches the current owner.
        #expect(firstResolved.backgroundProminence == .increased)
        #expect(firstEvent == .incident(source: "first", message: "first"))
        #expect(secondEvent == .incident(source: "second", message: "second"))
        #expect(secondResolved.viewEvent.wrappedValue == secondEvent)
    }

    @Test(arguments: [false, true])
    func givenNativeCellBackgroundStyle_whenNaturalMeasurementRuns_thenMeasurementProminenceMatchesObservedStyle(
        emphasized: Bool
    ) throws {
        // given
        _ = NSApplication.shared
        let coordinator = SidebarNativeList.Coordinator()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let outline = SidebarOwnedOutlineView(frame: scroll.bounds)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Measurement"))
        column.width = 320
        outline.addTableColumn(column)
        scroll.documentView = outline
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        try #require(window.canBecomeKey, "The native prominence contract requires a key-capable window")
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFrontRegardless()
        defer { window.contentView = nil; window.close() }
        try #require(outline.window === window, "The outline was not attached to the tested window")
        window.displayIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        outline.layoutSubtreeIfNeeded()
        coordinator.install(scroll: scroll, outline: outline)
        coordinator.environment = EnvironmentValues()
        let entry = SidebarListEntry(id: "task:measurement", content: .item(.task(TaskRowModel(
            id: "measurement", backend: "codex", title: "Measured", status: .completed,
            repoName: "repo", ageText: "1m"))))
        let box = SidebarNativeItemBox(entry)
        coordinator.boxes = [box]
        coordinator.boxesByID[entry.displayID] = box
        coordinator.indexesByID[entry.displayID] = 0
        let cell = coordinator.cell(for: box, outline: outline)
        cell.backgroundStyle = emphasized ? .emphasized : .normal
        box.naturalHeight = nil
        box.measurementKey = nil

        // when
        _ = coordinator.measureNatural(box)

        // then — compare with the AppKit cell's observed style, not a guessed selection formula.
        let observedProminence = cell.backgroundStyle == .emphasized
        let retainedProminence = try #require(cell.host?.rootView.increasedProminence as Bool?)
        let measurementProminence = try #require(box.measurementKey?.emphasized as Bool?)
        #expect(retainedProminence == observedProminence)
        #expect(measurementProminence == observedProminence)
    }
}
