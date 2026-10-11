import AppKit
@testable import MainWindowFeature
import Observation
import PbRepository
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

/// Hosted native-list measurements.  These intentionally measure the representable in a real
/// window; the numbers describe the native-list coordinator only, not the enclosing SidebarView.
@MainActor
@Suite(.serialized)
struct SidebarNativeHostedScalingTests {
    @Test(arguments: [100, 1_000, 10_000])
    func givenHostedNativeList_whenScalingStagesRun_thenCountersAndPresentationRemainObservable(_ count: Int) async throws {
        // given
        let state = HostedScalingState(presentation: presentation(count: count))
        let fixture = try await HostedScalingFixture(state: state)
        defer { fixture.close() }
        await fixture.waitForRows(count + 3, timeout: count >= 10_000 ? 60 : 30)
        await fixture.waitForSettled(timeout: count >= 10_000 ? 60 : 30)
        let coordinator = fixture.coordinator
        let retainedID = "task:row-0"
        let retainedDisplayID = SidebarDisplayID(logicalID: retainedID)
        let retainedCell = try #require(coordinator.cells[retainedDisplayID])
        let retainedHost = try #require(retainedCell.host)

        // A height request is measurement-only. Use an actual coordinator box that has not been
        // mounted when the native viewport leaves one available; do not fabricate a box.
        if let offscreen = coordinator.boxes.first(where: { !coordinator.seenIDs.contains($0.entry.id) }) {
            let offscreenID = offscreen.entry.id
            offscreen.height = nil
            offscreen.naturalHeight = nil
            offscreen.measurementKey = nil
            _ = coordinator.outlineView(fixture.outline, heightOfRowByItem: offscreen)
            #expect(!coordinator.seenIDs.contains(offscreenID))
            #expect(!coordinator.pendingMounted.contains(offscreen.entry.displayID))
            #expect(!state.seenIDs.contains(offscreenID))
            let row = fixture.outline.row(forItem: offscreen)
            if row >= 0 {
                #expect(fixture.outline.view(atColumn: 0, row: row, makeIfNecessary: false) == nil)
            }
        } else {
            // Small lists may legitimately realize every row in the native viewport. Larger
            // benchmarks must retain at least one real, unmounted coordinator box.
            #expect(count < 1_000)
        }
        let initial = fixture.snapshot(stage: "initial", count: count)
        fixture.log(initial)

        // when — an equal poll reaches the retained native list.
        state.presentation = presentation(count: count)
        state.pollTick += 1
        // The observable poll publication itself is the proof that the equal state was submitted;
        // SwiftUI/native equality may legitimately suppress a coordinator reconciliation.
        await waitUntil(timeout: 5) { state.pollTick == 1 }
        await fixture.waitForSettled(timeout: count >= 10_000 ? 60 : 30)
        let equal = fixture.snapshot(stage: "equal", count: count)
        fixture.log(equal)

        // then — equal content does no native work, while actual rows remain retained.
        #expect(equal.measurementCount == initial.measurementCount)
        #expect(equal.rootWriteCount == initial.rootWriteCount)
        #expect(equal.nativeOperationCount == initial.nativeOperationCount)
        #expect(coordinator.cells[retainedDisplayID].map(ObjectIdentifier.init) == ObjectIdentifier(retainedCell))
        #expect(coordinator.cells[retainedDisplayID]?.host.map(ObjectIdentifier.init) == ObjectIdentifier(retainedHost))

        // when — one visible row changes content and its clock metadata changes in place.
        state.presentation = presentation(count: count, titleForFirst: "Updated title", ageForFirst: "2m")
        try await fixture.waitForDisplayedTitle("Updated title", id: retainedID)
        let content = fixture.snapshot(stage: "content-and-clock", count: count)
        fixture.log(content)

        // then — the changed entry is displayed without a new native identity.
        #expect(coordinator.boxesByID[retainedDisplayID]?.entry.content != nil)
        #expect(coordinator.cells[retainedDisplayID].map(ObjectIdentifier.init) == ObjectIdentifier(retainedCell))
        #expect(coordinator.cells[retainedDisplayID]?.host.map(ObjectIdentifier.init) == ObjectIdentifier(retainedHost))

        _ = try await runPageReorderAndResize(state: state, fixture: fixture, count: count, coordinator: coordinator)
    }

    private func runPageReorderAndResize(
        state: HostedScalingState,
        fixture: HostedScalingFixture,
        count: Int,
        coordinator: SidebarNativeList.Coordinator
    ) async throws -> Snapshot {
        let initialTaskIDs = Set((0 ..< count).map { "task:row-\($0)" })
        let retainedDisplayID = SidebarDisplayID(logicalID: "task:row-0")
        let retainedBox = try #require(coordinator.boxesByID[retainedDisplayID])
        state.presentation = presentation(count: count + 1)
        await fixture.waitForRows(count + 4, timeout: count >= 10_000 ? 60 : 30)
        await fixture.waitForSettled(timeout: count >= 10_000 ? 60 : 30)
        let page = fixture.snapshot(stage: "page-append", count: count + 1)
        fixture.log(page)
        #expect(fixture.taskIDs == Set((0 ... count).map { "task:row-\($0)" }))
        state.presentation = presentation(rows: rows(count: count + 1).reversed())
        await fixture.waitForOrder(
            rows(count: count + 1).reversed().map { "task:\($0.id)" },
            timeout: count >= 10_000 ? 60 : 30
        )
        await fixture.waitForSettled(timeout: count >= 10_000 ? 60 : 30)
        let reordered = fixture.snapshot(stage: "reorder", count: count + 1)
        fixture.log(reordered)
        #expect(fixture.taskIDs == initialTaskIDs.union(["task:row-\(count)"]))
        #expect(coordinator.boxesByID[retainedDisplayID].map(ObjectIdentifier.init) == ObjectIdentifier(retainedBox))

        let beforeWidth = fixture.window.contentView?.bounds.width ?? 0
        fixture.window.setFrame(
            NSRect(
                x: fixture.window.frame.minX,
                y: fixture.window.frame.minY,
                width: fixture.window.frame.width + 120,
                height: fixture.window.frame.height
            ),
            display: true
        )
        await fixture.waitForWidthChange(from: beforeWidth)
        await fixture.waitForSettled(timeout: count >= 10_000 ? 60 : 30)
        let resized = fixture.snapshot(stage: "resize", count: count + 1)
        fixture.log(resized)
        #expect(resized.mainApplySeconds >= 0)
        #expect(resized.naturalMeasurementSeconds >= 0)
        #expect(resized.measurementCount >= reordered.measurementCount)
        #expect(coordinator.boxes.count == count + 4)
        #expect(coordinator.boxes.map(\.entry.id).count == count + 4)
        return reordered
    }

    private func presentation(count: Int, titleForFirst: String = "Row 0", ageForFirst: String = "1m") -> SidebarListPresentation {
        presentation(rows: rows(count: count, titleForFirst: titleForFirst, ageForFirst: ageForFirst))
    }

    private func presentation(rows: [TaskRowModel]) -> SidebarListPresentation {
        SidebarListPresentation(sections: [SidebarSection(bucket: .today, items: rows.map(SidebarItem.task))],
                                workflowTitles: [], workflowsExpanded: true, banner: nil, listError: nil,
                                skeleton: false, taskHistory: HistoryLoadingState(), workflowHistory: HistoryLoadingState(),
                                emptyMessage: nil, fadingIDs: [], minimumRowHeight: 0, historyRevision: 4,
                                historyToken: "hosted-scaling")
    }

    private func rows(count: Int, titleForFirst: String = "Row 0", ageForFirst: String = "1m") -> [TaskRowModel] {
        (0 ..< count).map { index in
            TaskRowModel(id: "row-\(index)", backend: "codex",
                         title: index == 0 ? titleForFirst : "Row \(index)", status: .completed,
                         repoName: "repo", ageText: index == 0 ? ageForFirst : "1m")
        }
    }
}

@MainActor @Observable
private final class HostedScalingState {
    var presentation: SidebarListPresentation
    var pollTick = 0
    var seenIDs: Set<String> = []
    init(presentation: SidebarListPresentation) { self.presentation = presentation }
}

private struct HostedScalingView: View {
    let state: HostedScalingState
    var body: some View {
        SidebarNativeList(presentation: state.presentation, selection: nil, seenIDs: state.seenIDs, configureActions: { actions in
            actions.mounted = { mounted in
                let newIDs = mounted.subtracting(state.seenIDs)
                if !newIDs.isEmpty { state.seenIDs.formUnion(newIDs) }
            }
        })
            .overlay(Text("\(state.pollTick)").hidden())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private final class HostedScalingFixture {
    let state: HostedScalingState
    let controller: NSHostingController<AnyView>
    let window: NSWindow
    let outline: SidebarOwnedOutlineView

    init(state: HostedScalingState) async throws {
        _ = NSApplication.shared
        let localController = NSHostingController(rootView: AnyView(HostedScalingView(state: state)))
        localController.sceneBridgingOptions = .all
        let localWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 500),
                                   styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        localWindow.isReleasedWhenClosed = false
        localWindow.contentView = localController.view
        localWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let hostedView = localController.view
        await waitUntil(timeout: 30) {
            hostedView.layoutSubtreeIfNeeded()
            return Self.descendants(hostedView).compactMap { $0 as? NSOutlineView }.first?.numberOfRows ?? 0 > 0
        }
        let localOutline = try #require(Self.descendants(hostedView).compactMap { $0 as? SidebarOwnedOutlineView }.first)
        self.state = state
        self.controller = localController
        self.window = localWindow
        self.outline = localOutline
    }

    var coordinator: SidebarNativeList.Coordinator {
        guard let coordinator = outline.delegate as? SidebarNativeList.Coordinator else {
            preconditionFailure("Hosted scaling outline delegate is not SidebarNativeList.Coordinator")
        }
        return coordinator
    }

    var taskIDs: Set<String> { Set(coordinator.boxes.compactMap { $0.entry.id.hasPrefix("task:") ? $0.entry.id : nil }) }

    func waitForRows(_ count: Int, timeout: TimeInterval) async {
        await waitUntil(timeout: timeout) { self.layout(); return self.outline.numberOfRows == count && self.coordinator.appliedEntries.count == count }
    }

    func waitForReconciliation(after count: Int) async {
        await waitUntil(timeout: 30) { self.layout(); return self.coordinator.reconciliationCount > count && !self.coordinator.appliedEntries.isEmpty }
    }

    func waitForSettled(timeout: TimeInterval) async {
        var previous = ""
        var unchanged = 0
        await waitUntil(timeout: timeout) {
            self.layout()
            let coordinator = self.coordinator
            let current = [
                coordinator.measurementCount,
                coordinator.createdCellCount,
                coordinator.rootWriteCount,
                coordinator.nativeOperationCount,
                coordinator.reconciliationCount,
                coordinator.boxes.count
            ]
.map(String.init)
.joined(separator: ":")
            if current == previous { unchanged += 1 } else { unchanged = 0; previous = current }
            return coordinator.reconciliation == nil && coordinator.detached == nil && unchanged >= 3
        }
    }

    func waitForDisplayedTitle(_ title: String, id: String) async throws {
        await waitUntil(timeout: 30) {
            self.layout()
            guard let cell = self.coordinator.cells[SidebarDisplayID(logicalID: id)],
                  let host = cell.host else { return false }
            guard case .item(.task(let item)) = host.rootView.entry.content else { return false }
            return item.title == title
        }
    }

    func waitForOrder(_ ids: [String], timeout: TimeInterval) async {
        await waitUntil(timeout: timeout) {
            self.layout()
            return self.coordinator.boxes.map(\.entry.id).filter { $0.hasPrefix("task:") } == ids
        }
    }

    func waitForWidthChange(from width: CGFloat) async {
        await waitUntil(timeout: 30) { self.layout(); return abs(self.coordinator.knownWidth - width) > 1 }
    }

    func layout() {
        controller.view.layoutSubtreeIfNeeded()
        outline.layoutSubtreeIfNeeded()
        outline.displayIfNeeded()
    }

    func snapshot(stage: String, count: Int) -> Snapshot {
        Snapshot(stage: stage, count: count, measurementCount: coordinator.measurementCount,
                 createdCellCount: coordinator.createdCellCount, rootWriteCount: coordinator.rootWriteCount,
                 nativeOperationCount: coordinator.nativeOperationCount, reconciliationCount: coordinator.reconciliationCount,
                 offMainCalculationSeconds: coordinator.offMainCalculationSeconds,
                 mainApplySeconds: coordinator.mainApplySeconds, naturalMeasurementSeconds: coordinator.naturalMeasurementSeconds)
    }

    func log(_ snapshot: Snapshot) { print("SidebarNativeHostedScaling \(snapshot)") }

    func close() { window.contentView = nil; window.close() }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

private struct Snapshot: CustomStringConvertible {
    let stage: String
    let count: Int
    let measurementCount: Int
    let createdCellCount: Int
    let rootWriteCount: Int
    let nativeOperationCount: Int
    let reconciliationCount: Int
    let offMainCalculationSeconds: TimeInterval
    let mainApplySeconds: TimeInterval
    let naturalMeasurementSeconds: TimeInterval

    var description: String {
        [
            "stage=\(stage)", "rows=\(count)", "measurements=\(measurementCount)",
            "cells=\(createdCellCount)", "roots=\(rootWriteCount)",
            "nativeOps=\(nativeOperationCount)", "reconciliations=\(reconciliationCount)",
            "offMain=\(offMainCalculationSeconds)", "mainApply=\(mainApplySeconds)",
            "natural=\(naturalMeasurementSeconds)"
        ].joined(separator: " ")
    }
}
