import AppKit
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

/// Production-context checks for the adapter inside the real NavigationSplitView shell.
@MainActor
@Suite(.serialized)
struct SidebarNativeWindowHostedTests {
    @Test(arguments: [false, true])
    func givenRealSidebarVM_whenCollapsingAndReExpandingAcrossMotionPolicies_thenNativeHeightsReverseWithoutStaleChildren(_ dark: Bool) async throws {
        for reduceMotion in [false, true] {
            let fixture = try await NativeSidebarWindowFixture(dark: dark, reduceMotion: reduceMotion)
            defer { fixture.close() }
            await fixture.settle()
            let children = fixture.nativeIDs.filter { $0.contains("abc123-child") }
            #expect(children.count == 2)
            let first = try #require(children.first)
            let expandedHeight = fixture.rowHeight(for: first)
            #expect(expandedHeight > PbRadius.Metrics.hairlineStroke)

            try fixture.toggleThroughSidebarAction(taskID: "root")
            await fixture.model.waitForPresentation()
            if reduceMotion {
                await waitUntil(timeout: 5) {
                    fixture.layout()
                    return children.allSatisfy { fixture.row(for: $0) == nil }
                }
            } else {
                try await runAnimatedMotionCase(fixture: fixture, children: children, first: first, expandedHeight: expandedHeight)
            }
            #expect(fixture.outline.selectedRowIndexes.isEmpty)

            if reduceMotion {
                fixture.model.didToggleExpansion(taskID: "root")
                await fixture.model.waitForPresentation()
            }
            await waitUntil(timeout: 5) {
                fixture.layout()
                return children.allSatisfy { fixture.row(for: $0) != nil }
            }
            #expect(fixture.rowsAreContiguous())
            for child in children {
                #expect(fixture.isFullyMeasured(child))
            }
        }
    }

    private func runAnimatedMotionCase(
        fixture: NativeSidebarWindowFixture,
        children: [String],
        first: String,
        expandedHeight: CGFloat
    ) async throws {
        var reversed = false
        var collapsingSamples: [HeightSample] = []
        var expandingSamples: [HeightSample] = []
        var expanding = false
        var sawExpansionIntermediate = false
        await waitUntil(timeout: 5) {
            fixture.layout()
            guard fixture.row(for: first) != nil else { return false }
            guard let sample = fixture.heightSample(for: first) else { return false }
            if expanding { expandingSamples.append(sample) } else { collapsingSamples.append(sample) }
            let height = sample.native
            let intermediate = height > PbRadius.Metrics.hairlineStroke
                && height < expandedHeight - PbRadius.Metrics.hairlineStroke
            if intermediate, !reversed {
                reversed = true
                expanding = true
                try? fixture.toggleThroughSidebarAction(taskID: "root")
            }
            if expanding, intermediate { sawExpansionIntermediate = true }
            return sawExpansionIntermediate && children.allSatisfy { fixture.row(for: $0) != nil }
        }
        #expect(reversed)
        #expect(sawExpansionIntermediate)
        await fixture.model.waitForPresentation()
        #expect(collapsingSamples.contains {
            $0.native > PbRadius.Metrics.hairlineStroke
                && $0.native < expandedHeight - PbRadius.Metrics.hairlineStroke
        })
        let collapsingWithinHairline = collapsingSamples.allSatisfy { sample in sample.isWithinHairline }
        let expandingWithinHairline = expandingSamples.allSatisfy { sample in sample.isWithinHairline }
        #expect(collapsingWithinHairline)
        #expect(expandingWithinHairline)
        #expect(zip(collapsingSamples, collapsingSamples.dropFirst()).allSatisfy { $1.native <= $0.native + 1 })
        #expect(zip(expandingSamples, expandingSamples.dropFirst()).allSatisfy { $1.native + 1 >= $0.native })
        await waitUntil(timeout: 5) {
            fixture.layout()
            return children.allSatisfy { fixture.isFullyMeasured($0) }
        }
        #expect(children.allSatisfy { fixture.isFullyMeasured($0) })
    }

    @Test func givenActualSidebarView_whenRowsCollapse_thenOutgoingIdentityIsRetainedUntilRemoval() async throws {
        let fixture = try await NativeSidebarWindowFixture()
        defer { fixture.close() }
        await fixture.settle()
        let childSourceID = try #require(
            fixture.model.recentRows.first { $0.id.contains("abc123-child") }?.id,
            "Model rows=\(fixture.model.recentRows.map(\.id)); native IDs=\(fixture.nativeIDs)"
        )
        let childID = "task:\(childSourceID)"
        let initialCount = fixture.outline.numberOfRows
        #expect(fixture.row(for: childID) != nil)
        fixture.model.didSelect(.task(childSourceID))
        await waitUntil(timeout: 5) {
            fixture.layout()
            return fixture.model.selection == .task(childSourceID)
                && !fixture.outline.selectedRowIndexes.isEmpty
        }

        fixture.model.didToggleExpansion(taskID: "root")
        await fixture.model.waitForPresentation()

        // then — outgoing identity is retained while disclosure closes, then removed.
        await waitUntil(timeout: 5) {
            fixture.layout()
            return fixture.row(for: childID) != nil && fixture.outline.numberOfRows == initialCount
                && fixture.isFading(childID)
        }
        await waitUntil(timeout: 5) {
            fixture.layout()
            return fixture.row(for: childID) == nil && fixture.outline.numberOfRows < initialCount
        }

        fixture.model.didToggleExpansion(taskID: "root")
        await fixture.model.waitForPresentation()

        await waitUntil(timeout: 5) {
            fixture.layout()
            return fixture.row(for: childID) != nil && !fixture.isFading(childID)
        }
        let restored = fixture.row(for: childID)
        let restoreDiagnostic = "Re-expansion did not restore \(childID); model IDs="
            + "\(fixture.model.sections.flatMap(\.items).map(\.id)), native IDs=\(fixture.nativeIDs), "
            + "fading=\(fixture.fadingIDs)"
        #expect(restored != nil, Comment(rawValue: restoreDiagnostic))
        if let restored {
            #expect(fixture.outline.rect(ofRow: restored).height >= PbRadius.Metrics.hairlineStroke)
        }
    }

    @Test func givenRealSidebarShell_whenEnteringAndLeavingFullScreen_thenHeaderFooterAndRowsStayInContentLayout() async throws {
        let fixture = try await NativeSidebarWindowFixture()
        defer { fixture.close() }
        await fixture.settle()
        let before = try fixture.geometry()

        fixture.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let transitions = FullScreenNotifications(window: fixture.window)
        defer { transitions.stop() }
        fixture.window.toggleFullScreen(nil)
        await waitUntil(timeout: 10) {
            transitions.entered && fixture.window.styleMask.contains(.fullScreen)
        }

        fixture.layout()
        let fullscreen = try fixture.geometry()
        fixture.assertInsideContentLayout(fullscreen)
        #expect(fullscreen.scrollFrame.height > 0)
        #expect(fullscreen.scrollFrame.maxY <= fullscreen.contentLayout.maxY + 1)
        fixture.assertNativeRowsMeasured()
        fixture.assertOwnedScrollGeometry()

        // when
        fixture.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        fixture.window.toggleFullScreen(nil)
        await waitUntil(timeout: 10) {
            transitions.exited && !fixture.window.styleMask.contains(.fullScreen)
        }

        // then
        fixture.layout()
        let restored = try fixture.geometry()
        fixture.assertInsideContentLayout(restored)
        #expect(restored.searchFrame.maxY <= restored.contentLayout.maxY + 1)
        #expect(restored.scrollFrame.height > 0)
        #expect(before.scrollFrame.width > 0)
        fixture.assertNativeRowsMeasured()
        fixture.assertOwnedScrollGeometry()
    }

    @Test func givenRealProducerTreeAndParallelGroupAliases_whenHosted_thenBothNativeOccurrencesRemainSelectableInOrder() async throws {
        // given — the real SidebarView/native list receives child tasks through both producers.
        let fixture = try await NativeSidebarWindowFixture(aliasFixture: true)
        defer { fixture.close() }
        fixture.model.didToggleExpansion(taskID: "group:g")
        await fixture.model.waitForPresentation()
        await fixture.settle()

        // then — both producers retain both logical children in native order.
        #expect(fixture.nativeIDs.filter { $0 == "task:g1" || $0 == "task:g2" }
            == ["task:g1", "task:g2", "task:g1", "task:g2"])
        #expect(fixture.outline.selectedRowIndexes.isEmpty)

        // when — native selection targets each actual alias row.
        let aliasRows = (0 ..< fixture.outline.numberOfRows).filter {
            let id = (fixture.outline.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id
            return id == "task:g1" || id == "task:g2"
        }
        try #require(aliasRows.count == 4)
        fixture.outline.selectRowIndexes(IndexSet(integer: aliasRows[0]), byExtendingSelection: false)
        fixture.layout()
        await waitUntil(timeout: 5) {
            fixture.layout()
            return fixture.model.selection == .task("g1")
        }

        // then — one logical route highlights every physical alias with that destination.
        let g1Rows = [aliasRows[0], aliasRows[2]]
        let nonAliasRow = try #require((0 ..< fixture.outline.numberOfRows).first { !g1Rows.contains($0) && !aliasRows.contains($0) })
        await waitUntil(timeout: 5) {
            fixture.layout()
            return fixture.outline.selectedRowIndexes == IndexSet(g1Rows)
                && g1Rows.allSatisfy { row in
                    (fixture.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarNativeCell)?.host?.rootView.selected == true
                }
                && (fixture.outline.view(atColumn: 0, row: nonAliasRow, makeIfNecessary: true) as? SidebarNativeCell)?.host?.rootView.selected == false
        }
        #expect(fixture.outline.selectedRowIndexes == IndexSet(g1Rows))
        let coordinator = try #require(fixture.outline.delegate as? SidebarNativeList.Coordinator)
        var routedDestinations: [MonitorDestination?] = []
        coordinator.actions.select = { routedDestinations.append($0) }
        fixture.outline.selectRowIndexes(IndexSet(integer: aliasRows[2]), byExtendingSelection: false)
        await waitUntil(timeout: 5) {
            fixture.layout()
            return fixture.outline.selectedRowIndexes == IndexSet(g1Rows)
        }
        #expect(fixture.outline.selectedRowIndexes == IndexSet(g1Rows))
        #expect(routedDestinations == [.task("g1")])

        // when — the native deselection route is used.
        coordinator.actions.select = { fixture.model.didSelect($0) }
        fixture.outline.deselectAll(nil)
        await waitUntil(timeout: 5) {
            fixture.layout()
            return fixture.model.selection == nil
        }
        #expect(fixture.outline.selectedRowIndexes.isEmpty)
    }

    @Test func givenHeldNativeReconciliation_whenAliasEnds_thenStaleResultCannotResurrectIt() async throws {
        // given — an expanded real alias fixture and a production reconciliation barrier.
        let fixture = try await NativeSidebarWindowFixture(aliasFixture: true)
        defer { fixture.close() }
        fixture.model.didToggleExpansion(taskID: "group:g")
        await fixture.model.waitForPresentation()
        await fixture.settle()
        let coordinator = try #require(fixture.outline.delegate as? SidebarNativeList.Coordinator)
        let gate = ReconciliationGate()
        coordinator.reconciliationBarrier = { await gate.wait() }
        let beforeRejected = coordinator.rejectedResultCount
        let beforeRevision = coordinator.appliedRevision

        // when — a detached result is held, then the logical alias ends synchronously.
        fixture.model.didToggleExpansion(taskID: "group:g")
        await gate.waitUntilEntered()
        coordinator.transition(ids: ["task:g1"], restored: [], epoch: 9, ended: true)
        await gate.release()
        await fixture.model.waitForPresentation()
        await waitUntil(timeout: 5) {
            fixture.layout()
            return coordinator.reconciliation == nil && coordinator.detached == nil
        }

        // then — the applied base rejects the old result and no ended alias remains.
        #expect(coordinator.appliedRevision > beforeRevision)
        #expect(coordinator.rejectedResultCount >= beforeRejected)
        #expect(!fixture.nativeIDs.contains("task:g1"))
        #expect(coordinator.logicalDisplays["task:g1"]?.isEmpty != false)
    }

    @Test func givenCollapsedAndReexpandedAlias_whenOldNativeCallbacksArrive_thenFreshBoxRejectsThem() async throws {
        // given — capture the real group-owned occurrence and its native callback generation.
        let fixture = try await NativeSidebarWindowFixture(aliasFixture: true)
        defer { fixture.close() }
        fixture.model.didToggleExpansion(taskID: "group:g")
        await fixture.model.waitForPresentation()
        await fixture.settle()
        let coordinator = try #require(fixture.outline.delegate as? SidebarNativeList.Coordinator)
        let oldDisplayID = try #require(coordinator.logicalDisplays["task:g1"]?.first { $0.ownerID == "group:g" })
        let oldBox = try #require(coordinator.boxesByID[oldDisplayID])
        let oldCell = try #require(coordinator.cells[oldDisplayID])
        let staleLayoutCallback = oldCell.onLaidOut
        let oldGeneration = oldBox.reportGeneration
        let oldNativeID = oldBox.entry.nativeID

        // when — collapse and re-expand the same group in the same transition epoch.
        fixture.model.didToggleExpansion(taskID: "group:g")
        await fixture.model.waitForPresentation()
        await waitUntil(timeout: 5) {
            fixture.layout()
            return coordinator.logicalDisplays["task:g1"]?.contains(oldDisplayID) != true
        }
        fixture.model.didToggleExpansion(taskID: "group:g")
        await fixture.model.waitForPresentation()
        await fixture.settle()
        let newBox = try #require(coordinator.boxesByID[oldDisplayID])
        #expect(newBox.entry.nativeID != oldNativeID)

        // then — a callback captured from the removed incarnation cannot mutate the replacement.
        let callbackRevision = coordinator.appliedRevision
        coordinator.pendingMounted.removeAll()
        staleLayoutCallback?()
        #expect(!coordinator.pendingMounted.contains(oldDisplayID))
        coordinator.recordHostedHeight(999, box: oldBox, cell: oldCell, generation: oldGeneration)
        #expect(coordinator.appliedRevision == callbackRevision)
        #expect(newBox.latestHostedReport != 999)
        #expect(newBox.height != 999)
        #expect(!coordinator.pendingHostedHeights.contains(oldDisplayID))
    }
}

private actor ReconciliationGate {
    private var entered = false
    private var released = false

    func wait() async {
        entered = true
        while !released { await Task.yield() }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func release() {
        released = true
    }
}

@MainActor
final class NativeSidebarWindowFixture {
    let harness: SidebarVMTests.SUT
    let model: SidebarVM
    let controller: NSHostingController<AnyView>
    let host: NSView
    let window: NSWindow
    let outline: NSOutlineView

    init(dark: Bool = false, reduceMotion: Bool? = nil, aliasFixture: Bool = false) async throws {
        _ = NSApplication.shared
        let testHarness = SidebarVMTests().makeSUT(connectionLine: "connected")
        let localModel = testHarness.sut
        self.harness = testHarness
        self.model = localModel
        testHarness.titlesBox.value = [
            "root": "Parent task",
            "abc123-child": "A long child task title that produces a measurable multiline native row",
            "abc123-child-2": "Another child task",
            "g1": "Group child one",
            "g2": "Group child two"
        ]
        localModel.didAppear()
        await localModel.waitForPresentation()
        testHarness.tasksSubject.send(aliasFixture ? [
            SidebarVMTests().task(id: "root", status: "completed"),
            SidebarVMTests().task(id: "g1", status: "completed", group: "g", spawnedBy: "root"),
            SidebarVMTests().task(id: "g2", status: "completed", group: "g", spawnedBy: "root")
        ] : [
            SidebarVMTests().task(id: "root", status: "completed"),
            SidebarVMTests().task(id: "abc123-child", status: "completed", spawnedBy: "root"),
            SidebarVMTests().task(id: "abc123-child-2", status: "completed", spawnedBy: "root")
        ])
        testHarness.hasListedSubject.send(true)
        await waitUntil { localModel.recentRows.count == 3 }
        await localModel.waitForPresentation()
        let root = AnyView(NavigationSplitView {
            SidebarView(localModel)
                .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 340)
                .preferredColorScheme(dark ? .dark : .light)
                .environment(\.pbReduceMotionOverride, reduceMotion)
        } detail: {
            Text("Detail")
        }
.frame(minWidth: 640, minHeight: 760)
.withPresentationContext())
        self.controller = NSHostingController(rootView: root)
        controller.sceneBridgingOptions = .all
        self.host = controller.view
        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "sidebar-native-window")
        window.toolbarStyle = .unified
        window.collectionBehavior = [.fullScreenPrimary, .fullScreenAllowsTiling]
        window.contentView = host
        window.orderFront(nil)
        let hostedView = host
        await waitUntil(timeout: 5) {
            hostedView.layoutSubtreeIfNeeded()
            return Self.descendants(hostedView).compactMap { $0 as? NSOutlineView }.first?.numberOfRows ?? 0 > 0
        }
        self.outline = try #require(Self.descendants(hostedView).compactMap { $0 as? NSOutlineView }.first)
    }

    func settle() async {
        var stablePasses = 0
        var previousHeights: [String: CGFloat] = [:]
        await waitUntil(timeout: 5) {
            layout()
            let expectedIDs = Set(model.sections.flatMap(\.items).map(\.id))
            guard outline.numberOfRows > 0, outline.rect(ofRow: outline.numberOfRows - 1).height > 0,
                  expectedIDs.isSubset(of: Set(nativeIDs)) else { return false }
            let heights = Dictionary(uniqueKeysWithValues: expectedIDs.compactMap { id -> (String, CGFloat)? in
                guard let row = row(for: id),
                      let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarNativeCell,
                      let host = cell.host,
                      host.frame.width > 0,
                      host.fittingSize.height > PbRadius.Metrics.hairlineStroke,
                      outline.rect(ofRow: row).height >= host.fittingSize.height - 1
                else { return nil }
                return (id, outline.rect(ofRow: row).height)
            })
            guard heights.count == expectedIDs.count else {
                stablePasses = 0
                previousHeights = heights
                return false
            }
            if heights == previousHeights { stablePasses += 1 } else { stablePasses = 0 }
            previousHeights = heights
            return stablePasses >= 3
        }
    }

    func row(for id: String) -> Int? {
        (0 ..< outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id == id }
    }

    func rowHeight(for id: String) -> CGFloat {
        guard let row = row(for: id) else { return 0 }
        return outline.rect(ofRow: row).height
    }

    fileprivate func heightSample(for id: String) -> HeightSample? {
        guard let row = row(for: id), let box = outline.item(atRow: row) as? SidebarNativeItemBox,
              let reported = box.latestHostedReport,
              let rowView = outline.rowView(atRow: row, makeIfNecessary: false) else { return nil }
        return HeightSample(rect: outline.rect(ofRow: row).height, frame: rowView.frame.height,
                            reported: reported)
    }

    func isFullyMeasured(_ id: String) -> Bool {
        guard let row = row(for: id),
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarNativeCell,
              let fittingHeight = cell.host?.fittingSize.height else { return false }
        return outline.rect(ofRow: row).height >= fittingHeight - 1
    }

    func rowsAreContiguous() -> Bool {
        let rects = (0 ..< outline.numberOfRows).map { outline.rect(ofRow: $0) }
        return zip(rects, rects.dropFirst()).allSatisfy { current, next in
            next.minY >= current.maxY - PbRadius.Metrics.hairlineStroke
        }
    }

    func assertNativeRowsMeasured() {
        for row in 0 ..< outline.numberOfRows {
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarNativeCell,
                  let fittingHeight = cell.host?.fittingSize.height else {
                #expect(Bool(false), "Missing realized native cell at row \(row)")
                continue
            }
            #expect(outline.rect(ofRow: row).height >= PbRadius.Metrics.hairlineStroke)
            #expect(outline.rect(ofRow: row).height >= fittingHeight - 1)
        }
    }

    func assertOwnedScrollGeometry() {
        guard let scroll = outline.enclosingScrollView else {
            #expect(Bool(false), "Sidebar native list lost its owned scroll view")
            return
        }
        #expect(scroll.contentInsets.top == 0 && scroll.contentInsets.left == 0
            && scroll.contentInsets.bottom == 0 && scroll.contentInsets.right == 0)
        #expect(scroll.scrollerInsets.top == 0 && scroll.scrollerInsets.left == 0
            && scroll.scrollerInsets.bottom == 0 && scroll.scrollerInsets.right == 0)
        #expect(scroll.frame.width > 0)
        #expect(scroll.documentView?.frame.width ?? 0 > 0)
    }

    func toggleThroughSidebarAction(taskID: String) throws {
        let rootID = try #require(nativeIDs.first { $0.hasSuffix(":root") })
        let rootRow = try #require(row(for: rootID))
        let cell = try #require(outline.view(atColumn: 0, row: rootRow, makeIfNecessary: true) as? SidebarNativeCell)
        let host = try #require(cell.host)
        host.rootView.actions.toggle(taskID)
    }

    var nativeIDs: [String] {
        (0 ..< outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id }
    }

    var fadingIDs: [String] {
        (0 ..< outline.numberOfRows).compactMap {
            guard let box = outline.item(atRow: $0) as? SidebarNativeItemBox, box.entry.isFading else { return nil }
            return box.entry.id
        }
    }

    func isFading(_ id: String) -> Bool {
        guard let row = row(for: id), let box = outline.item(atRow: row) as? SidebarNativeItemBox else { return false }
        return box.entry.isFading
    }

    func layout() {
        host.layoutSubtreeIfNeeded()
        outline.layoutSubtreeIfNeeded()
        outline.displayIfNeeded()
    }

    fileprivate func geometry() throws -> SidebarShellGeometry {
        layout()
        let search = try #require(Self.descendants(host).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Search loaded history" })
        let scroll = try #require(outline.enclosingScrollView)
        return SidebarShellGeometry(
            contentLayout: window.contentLayoutRect,
            searchFrame: search.convert(search.bounds, to: nil),
            scrollFrame: scroll.convert(scroll.bounds, to: nil),
            effectiveViewportBottom: scroll.convert(scroll.bounds, to: nil).minY + scroll.contentInsets.bottom,
            effectiveViewportTop: scroll.convert(scroll.bounds, to: nil).maxY - scroll.contentInsets.top
        )
    }

    fileprivate func assertInsideContentLayout(_ geometry: SidebarShellGeometry) {
        #expect(geometry.searchFrame.maxY <= geometry.contentLayout.maxY + 1)
        #expect(geometry.scrollFrame.minY >= geometry.contentLayout.minY - 1)
        #expect(geometry.scrollFrame.maxY <= geometry.contentLayout.maxY + 1)
        #expect(geometry.effectiveViewportBottom >= geometry.contentLayout.minY - 1)
        #expect(geometry.effectiveViewportTop <= geometry.contentLayout.maxY + 1)
    }

    func close() {
        model.didDisappear()
        window.contentView = nil
        window.close()
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

struct HeightSample {
    let rect: CGFloat
    let frame: CGFloat
    let reported: CGFloat

    var native: CGFloat { rect }
    var isWithinHairline: Bool {
        abs(rect - frame) <= PbRadius.Metrics.hairlineStroke
            && abs(rect - reported) <= PbRadius.Metrics.hairlineStroke
            && abs(frame - reported) <= PbRadius.Metrics.hairlineStroke
    }
}

struct SidebarShellGeometry {
    let contentLayout: NSRect
    let searchFrame: NSRect
    let scrollFrame: NSRect
    let effectiveViewportBottom: CGFloat
    let effectiveViewportTop: CGFloat
}

@MainActor
private final class FullScreenNotifications {
    var entered = false
    var exited = false
    private var tokens: [NSObjectProtocol] = []

    init(window: NSWindow) {
        tokens.append(NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.entered = true }
        })
        tokens.append(NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.exited = true }
        })
    }

    func stop() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens.removeAll()
    }
}
