import AppKit
@testable import MainWindowFeature
import MonitorCore
import Observation
import PbCommon
import PbRepository
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

/// Native-renderer geometry checks for disclosure rows.  These tests intentionally host the
/// owned outline view, rather than exercising an isolated `SidebarDisclosureRow`, so a native
/// row slot, its hosted SwiftUI content, and the sentinel all participate in the assertions.
@MainActor
@Suite(.serialized)
struct SidebarNativeDisclosureHostedTests {
    @Test func givenOccupiedHeightBridge_whenDisclosureAnimates_thenReportsFiniteMonotonicPresentation() async throws {
        // given
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        _ = NSApplication.shared
        let state = OccupiedHeightProbeState()
        let host = NSHostingView(rootView: OccupiedHeightProbe(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        let naturalHeight: CGFloat = 60
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            return state.samples.contains { abs($0 - naturalHeight) <= 0.01 }
        }
        let expanded = try #require(state.samples.last { abs($0 - naturalHeight) <= 0.01 })
        #expect(abs(expanded - naturalHeight) <= 0.01)

        // when
        let collapseStart = state.samples.count
        state.visible = false

        // then — the callback is presentation-only and follows the existing disclosure motion.
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            return state.samples.last.map { $0 <= PbRadius.Metrics.hairlineStroke } ?? false
        }
        let collapse = Array(state.samples.dropFirst(collapseStart))
        #expect(collapse.allSatisfy { $0.isFinite && $0 >= 0 })
        #expect(collapse.contains { $0 > PbRadius.Metrics.hairlineStroke && $0 < expanded - PbRadius.Metrics.hairlineStroke })
        #expect(zip(collapse, collapse.dropFirst()).allSatisfy { $1 <= $0 + 1 })

        // when
        let expansionStart = state.samples.count
        state.visible = true

        // then
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            return state.samples.last.map { $0 >= expanded - 1 } ?? false
        }
        let expansion = Array(state.samples.dropFirst(expansionStart))
        #expect(zip(expansion, expansion.dropFirst()).allSatisfy { $1 + 1 >= $0 })
        #expect(state.samples.last ?? 0 >= expanded - 1)
    }

    @Test func givenMountedDisclosureRows_whenNativeLayoutSettles_thenSlotsFitWithoutOverlap() async throws {
        // given
        let state = NativeDisclosureState(presentation: presentation(items: [.task(task("first")), .task(task("second"))]))
        let fixture = try await NativeDisclosureFixture(state: state)
        defer { fixture.close() }

        // when
        await fixture.settle()
        await waitUntil(timeout: 5) { !state.mountedIDs.isEmpty }

        // then
        let rows = fixture.outline
        #expect(rows.numberOfRows >= 4) // section heading, two rows, history sentinel
        let rowRects = (0 ..< rows.numberOfRows).map { rows.rect(ofRow: $0) }
        #expect(rowRects.allSatisfy { $0.height >= PbRadius.Metrics.hairlineStroke })
        #expect(zip(rowRects, rowRects.dropFirst()).allSatisfy { current, next in
            next.minY >= current.maxY - PbRadius.Metrics.hairlineStroke
        })
        #expect(rows.rect(ofRow: rows.numberOfRows - 1).height >= PbRadius.Metrics.hairlineStroke)
        #expect(fixture.scroll.documentView?.frame.height ?? 0 >= fixture.scroll.contentView.bounds.height)
        #expect(state.mountedIDs.contains("header:today"))
        #expect(state.mountedIDs.contains("history:sentinel"))
        for row in 0 ..< rows.numberOfRows {
            let cell = try #require(rows.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarNativeCell)
            #expect(rows.rect(ofRow: row).height >= (cell.host?.fittingSize.height ?? 0) - 1)
        }
    }

    @Test func givenVisibleDisclosureRow_whenItFadesAndIsRemoved_thenFollowingRowMovesIntoItsSlot() async throws {
        // given
        let first = task("outgoing")
        let second = task("retained")
        let state = NativeDisclosureState(presentation: presentation(items: [.task(first), .task(second)]), selection: .task(first.id))
        let fixture = try await NativeDisclosureFixture(state: state)
        defer { fixture.close() }
        await fixture.settle()
        let outgoingID = SidebarItem.task(first).id
        let initialRows = fixture.outline.numberOfRows
        let retainedID = SidebarItem.task(second).id
        let retainedRowBefore = try #require(fixture.row(for: retainedID))
        let retainedYBefore = fixture.outline.rect(ofRow: retainedRowBefore).minY

        // when — first retain the identity with closed disclosure content, then remove it.
        state.presentation = presentation(items: [.task(first), .task(second)], fadingIDs: [outgoingID])
        await waitUntil(timeout: 5) {
            fixture.layout()
            return fixture.outline.numberOfRows == initialRows
                && fixture.row(for: outgoingID) != nil
                && fixture.rowHeight(for: outgoingID) <= PbRadius.Metrics.hairlineStroke + 1
        }
        #expect(fixture.row(for: outgoingID) != nil)
        #expect(fixture.rowHeight(for: outgoingID) >= PbRadius.Metrics.hairlineStroke)

        state.presentation = presentation(items: [.task(second)])

        // then — the removed row is gone and the following row occupies the released space.
        await waitUntil(timeout: 5) {
            fixture.layout()
            return fixture.outline.numberOfRows == initialRows - 1
                && fixture.row(for: outgoingID) == nil
        }
        let retainedRowAfter = try #require(fixture.row(for: retainedID))
        #expect(abs(fixture.outline.rect(ofRow: retainedRowAfter).minY - retainedYBefore) > PbRadius.Metrics.hairlineStroke)
        #expect(fixture.outline.rect(ofRow: retainedRowAfter).height >= PbRadius.Metrics.hairlineStroke)
        #expect(fixture.outline.selectedRowIndexes.isEmpty)
        #expect((0 ..< fixture.outline.numberOfRows).map { fixture.outline.rect(ofRow: $0) }.allSatisfy { $0.height >= PbRadius.Metrics.hairlineStroke })
    }

    @Test(arguments: [false, true])
    func givenReduceMotionOverride_whenDisclosureRowsAreHosted_thenGeometryRemainsValid(_ reduceMotion: Bool) async throws {
        // given
        let state = NativeDisclosureState(presentation: presentation(items: [.task(task("motion"))]))
        let fixture = try await NativeDisclosureFixture(state: state, reduceMotion: reduceMotion, dark: reduceMotion)
        defer { fixture.close() }

        // when
        await fixture.settle()

        // then — both motion policies keep native slots valid; policy selection is not a geometry
        // shortcut and does not remove the row or its sentinel.
        #expect(fixture.outline.numberOfRows >= 3)
        #expect((0 ..< fixture.outline.numberOfRows).map { fixture.outline.rect(ofRow: $0) }.allSatisfy { rect in
            rect.height >= PbRadius.Metrics.hairlineStroke && rect.width > 0
        })
    }

    @Test func givenMultipleMountedChildren_whenCollapsedAndReExpanded_thenNativeRowsReconcileBothDirections() async throws {
        // given
        let parent = task("parent", hasChildren: true)
        let childA = task("child-a")
        let childB = task("child-b")
        let following = task("following")
        let state = NativeDisclosureState(presentation: presentation(items: [.task(parent), .task(childA), .task(childB), .task(following)]))
        let fixture = try await NativeDisclosureFixture(state: state)
        defer { fixture.close() }
        await fixture.settle()
        let expandedCount = fixture.outline.numberOfRows

        // when — simulate the VM's flattened collapsed and expanded snapshots.
        state.presentation = presentation(items: [.task(parent), .task(following)])
        await waitUntil(timeout: 5) { fixture.layout(); return fixture.outline.numberOfRows == expandedCount - 2 }
        #expect(fixture.row(for: SidebarItem.task(childA).id) == nil)
        #expect(fixture.row(for: SidebarItem.task(childB).id) == nil)

        state.presentation = presentation(items: [.task(parent), .task(childA), .task(childB), .task(following)])

        // then — both children return with valid measured slots and the stable following row remains.
        await waitUntil(timeout: 5) {
            fixture.layout()
            return fixture.outline.numberOfRows == expandedCount
                && fixture.row(for: SidebarItem.task(childA).id) != nil
                && fixture.row(for: SidebarItem.task(childB).id) != nil
        }
        #expect(fixture.row(for: SidebarItem.task(following).id) != nil)
        #expect((0 ..< fixture.outline.numberOfRows).map { fixture.outline.rect(ofRow: $0) }.allSatisfy { rect in
            rect.height >= PbRadius.Metrics.hairlineStroke
        })
    }

    private func task(_ id: String, hasChildren: Bool = false) -> TaskRowModel {
        TaskRowModel(id: id, backend: "codex", title: "A disclosure row with enough content to measure", status: .completed,
                     repoName: "repo", ageText: "1h", indent: 0, hasChildren: hasChildren,
                     isExpanded: hasChildren)
    }

    private func presentation(items: [SidebarItem], fadingIDs: Set<String> = []) -> SidebarListPresentation {
        SidebarListPresentation(
            sections: [SidebarSection(bucket: .today, items: items)], workflowTitles: [], workflowsExpanded: true,
            banner: nil, listError: nil, skeleton: false, taskHistory: HistoryLoadingState(),
            workflowHistory: HistoryLoadingState(), emptyMessage: nil, fadingIDs: fadingIDs,
            minimumRowHeight: 0, historyRevision: 0, historyToken: "native-disclosure")
    }
}

@MainActor @Observable
private final class NativeDisclosureState {
    var presentation: SidebarListPresentation
    var selection: MonitorDestination?
    var mountedIDs: Set<String> = []
    let seenIDs: Set<String>

    init(presentation: SidebarListPresentation, selection: MonitorDestination? = nil) {
        self.presentation = presentation
        self.selection = selection
        self.seenIDs = Set(presentation.sections.flatMap(\.items).map(\.id))
    }
}

private struct NativeDisclosureHost: View {
    @State private var state: NativeDisclosureState
    private let reduceMotion: Bool?
    private let dark: Bool

    init(state: NativeDisclosureState, reduceMotion: Bool? = nil, dark: Bool = false) {
        _state = State(initialValue: state)
        self.reduceMotion = reduceMotion
        self.dark = dark
    }

    var body: some View {
        SidebarNativeList(
            presentation: state.presentation, selection: state.selection, seenIDs: state.seenIDs,
            configureActions: { actions in
                actions.mounted = { state.mountedIDs.formUnion($0) }
            }
        )
        .environment(\.pbReduceMotionOverride, reduceMotion)
        .preferredColorScheme(dark ? .dark : .light)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private final class NativeDisclosureFixture {
    let host: NSHostingView<AnyView>
    let window: NSWindow
    let scroll: NSScrollView
    let outline: NSOutlineView

    init(state: NativeDisclosureState, reduceMotion: Bool? = nil, dark: Bool = false) async throws {
        _ = NSApplication.shared
        self.host = NSHostingView(rootView: AnyView(NativeDisclosureHost(state: state, reduceMotion: reduceMotion, dark: dark)))
        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 500),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary, .fullScreenAllowsTiling]
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.toolbar = NSToolbar(identifier: "sidebar-native-disclosure")
        window.toolbarStyle = .unified
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let hostedView = host
        await waitUntil(timeout: 5) {
            hostedView.layoutSubtreeIfNeeded()
            return Self.descendants(hostedView).compactMap { $0 as? NSOutlineView }.first?.numberOfRows ?? 0 > 0
        }
        self.outline = try #require(Self.descendants(hostedView).compactMap { $0 as? NSOutlineView }.first)
        self.scroll = try #require(outline.enclosingScrollView)
    }

    func settle() async {
        await waitUntil(timeout: 5) {
            layout()
            return outline.numberOfRows > 0 && outline.rect(ofRow: outline.numberOfRows - 1).height > 0
        }
    }

    func waitForRows(_ count: Int) async {
        await waitUntil(timeout: 5) {
            layout()
            return outline.numberOfRows == count
        }
    }

    func row(for id: String) -> Int? {
        (0 ..< outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id == id }
    }

    func rowHeight(for id: String) -> CGFloat {
        guard let row = row(for: id) else { return 0 }
        return outline.rect(ofRow: row).height
    }

    func layout() {
        host.layoutSubtreeIfNeeded()
        outline.layoutSubtreeIfNeeded()
        outline.displayIfNeeded()
    }

    func close() {
        window.contentView = nil
        window.close()
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

@MainActor @Observable
private final class OccupiedHeightProbeState {
    var visible = true
    var samples: [CGFloat] = []
}

private struct OccupiedHeightProbe: View {
    let state: OccupiedHeightProbeState

    var body: some View {
        SidebarDisclosureRow(isVisible: state.visible, animate: true, onOccupiedHeight: { height in
            state.samples.append(height)
        }) {
            Text("Workflow child").frame(width: 280, height: 60)
        }
        .environment(\.pbReduceMotionOverride, false)
    }
}
