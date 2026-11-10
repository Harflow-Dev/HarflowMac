import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Observation
import SwiftUI
import Testing

// MARK: - TaskPaneHostedTests

/// Hosted behaviour of the standalone mount's right pane, over preview models: split and overlay by measured width,
/// one-pass settling across 900, per-conversation state across the coordinator's `.id` reset, the reveal and Escape
/// routes, the unchanged group and embedded mounts, and the pane's accessibility. Geometry is read from the hosted
/// accessibility tree and the activity table; state from the shared `TaskPaneStateStore`.
@MainActor @Suite(.serialized) struct TaskPaneHostedTests {
    static let conversation = "conv"

    func seededStore(
        open: TaskPaneStateStore.OpenChoice? = .open, tab: TaskPaneStateStore.Tab = .events,
        groups: Set<TaskPaneStateStore.FactsGroup> = [], id: String = conversation
    ) -> TaskPaneStateStore {
        let store = TaskPaneStateStore()
        if let open { store.setOpenChoice(open, for: id) }
        store.setSelectedTab(tab, for: id)
        store.setExpandedGroups(groups, for: id)
        return store
    }

    func mount(
        _ mock: TaskDetailViewModelMock, store: TaskPaneStateStore, width: CGFloat, height: CGFloat = 700, dark: Bool = false
    ) async -> PaneHost {
        let host = PaneHost(PaneMocks.standalone(mock, store: store), size: CGSize(width: width, height: height), dark: dark)
        // Ready once the transcript column is realised and, for a pane the person opened, the pane is on screen.
        await host.page.settle { host.columnWidth != nil && (store.openChoice(for: Self.conversation) != .open || host.hasPane) }
        return host
    }

    /// The labels the hosted view exposes at its top level. A modal pane leaves only itself.
    func topLevel(_ host: PaneHost) -> [String] {
        let children = host.page.host.accessibilityChildren() ?? []
        return children.compactMap { ($0 as? NSObject).flatMap { host.string($0, "accessibilityLabel") } }
    }

    func press(_ host: PaneHost, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let element = try #require(host.page.element(label), "no element labelled \(label)", sourceLocation: sourceLocation)
        #expect(host.page.press(element), "\(label) did not accept a press", sourceLocation: sourceLocation)
    }

    // MARK: - Split and overlay

    @Test(arguments: [900, 1000, 1280, 1600] as [CGFloat])
    func givenAnOpenPaneAtOrAboveNineHundred_whenMounted_thenItSitsBesideTheColumnAndIsNotModal(width: CGFloat) async throws {
        // given
        let store = seededStore()

        // when
        let host = await mount(PaneMocks.running(), store: store, width: width)
        defer { host.close() }

        // then
        let frame = try #require(host.paneFrame)
        let column = try #require(host.columnWidth)
        #expect(abs(frame.width - 420) <= 2, "pane width \(frame.width)")
        #expect(abs(frame.maxX - width) <= 2, "pane trailing edge \(frame.maxX)")
        #expect(abs(column - min(760, width - 420)) <= 2, "column \(column) at container \(width)")
        #expect(topLevel(host).contains("Task details") && topLevel(host).count > 1, "the column stays reachable beside a split pane")
    }

    @Test(arguments: [899, 700, 620] as [CGFloat])
    func givenAnOpenPaneBelowNineHundred_whenMounted_thenItOverlaysTheColumnWhichKeepsItsWidthAndTheOverlayIsModal(width: CGFloat) async throws {
        // given
        let closed = await mount(PaneMocks.running(), store: seededStore(open: .closed), width: width)
        let closedColumn = closed.columnWidth
        #expect(!closed.hasPane)
        closed.close()

        // when
        let host = await mount(PaneMocks.running(), store: seededStore(), width: width)
        defer { host.close() }

        // then
        let frame = try #require(host.paneFrame)
        let column = try #require(host.columnWidth)
        #expect(abs(frame.width - 420) <= 3, "pane width \(frame.width)")
        #expect(abs(frame.maxX - width) <= 3, "pane trailing edge \(frame.maxX)")
        #expect(column == closedColumn, "transcript width changed from \(String(describing: closedColumn)) to \(column)")
        #expect(topLevel(host) == ["Task details"], "an overlay pane is the only top-level accessibility element (modal)")
    }

    @Test func givenTheOverlayAndSplitPanes_whenComparingTheirAccessibilityNode_thenBothAreLabelledAndOnlyTheOverlayHidesTheColumn() async throws {
        // given / when
        let split = await mount(PaneMocks.running(), store: seededStore(), width: 1000)
        defer { split.close() }
        let overlay = await mount(PaneMocks.running(), store: seededStore(), width: 800)
        defer { overlay.close() }

        // then
        #expect(split.pane != nil && overlay.pane != nil)
        #expect(topLevel(split).contains("Queue a message…"))
        #expect(!topLevel(overlay).contains("Queue a message…"))
        #expect(overlay.page.element("Close right pane") != nil)
    }

    @Test func givenAPaneThatIsNotOpen_whenMounted_thenNothingOfItIsInTheTree() async {
        // given / when
        let host = await mount(PaneMocks.running(), store: seededStore(open: nil, tab: .changes), width: 1000)
        defer { host.close() }

        // then
        #expect(!host.hasPane)
        #expect(host.page.element("Close right pane") == nil)
        #expect(abs((host.columnWidth ?? 0) - 760) <= 2)
    }

    @Test func givenTheCloseButton_whenPressed_thenThePaneLeavesAndTheChoiceIsStored() async throws {
        // given
        let store = seededStore()
        let host = await mount(PaneMocks.running(), store: store, width: 1000)
        defer { host.close() }

        // when
        try press(host, "Close right pane")
        await host.page.settle { !host.hasPane }

        // then
        #expect(store.openChoice(for: Self.conversation) == .closed)
        #expect(!host.hasPane)
        #expect(abs((host.columnWidth ?? 0) - 760) <= 2)
    }

    @Test func givenTheTabs_whenSelected_thenTheStoreFollowsAndChangesIsOffered() async throws {
        // given
        let store = seededStore(tab: .events)
        let host = await mount(PaneMocks.running(), store: store, width: 1000)
        defer { host.close() }
        #expect(host.page.element("Changes") != nil)

        // when
        try press(host, "Changes")
        await host.page.settle { host.header("Task") == nil }

        // then
        #expect(store.selectedTab(for: Self.conversation) == .changes)

        // when
        try press(host, "Artifacts")
        await host.page.settle { host.header("Task") == nil }

        // then
        #expect(store.selectedTab(for: Self.conversation) == .artifacts)
        #expect(host.header("Task") == nil, "the facts groups belong to Events")

        // when
        try press(host, "Events")
        await host.page.settle { host.header("Task") != nil }

        // then
        #expect(store.selectedTab(for: Self.conversation) == .events)
        #expect(host.header("Task") != nil)
    }

    // MARK: - Default open

    @Test func givenADoneTaskWithAnObservedExit_whenFirstShownAtSplitWidth_thenThePaneIsOpenByDefaultAndStoresTheDefault() async {
        // given
        let store = TaskPaneStateStore()

        // when
        let host = await mount(PaneMocks.done(exit: 0), store: store, width: 1280)
        defer { host.close() }

        // then
        #expect(host.hasPane)
        #expect(store.appliedDefault(for: Self.conversation) == true)
        #expect(store.openChoice(for: Self.conversation) == .noChoice)
    }

    @Test func givenADefaultOpenPane_whenTheContainerShrinksBelowNineHundredAndGrowsBack_thenItClosesAndReopens() async {
        // given
        let host = await mount(PaneMocks.done(exit: 0), store: TaskPaneStateStore(), width: 1280)
        defer { host.close() }
        #expect(host.hasPane)

        // when / then
        host.resize(to: CGSize(width: 880, height: 700))
        await host.page.settle { !host.hasPane }
        #expect(!host.hasPane)
        host.resize(to: CGSize(width: 900, height: 700))
        await host.page.settle { host.hasPane }
        #expect(host.hasPane)
    }

    @Test func givenAPaneThePersonOpened_whenTheContainerShrinks_thenItStaysAsAnOverlay() async {
        // given
        let store = seededStore()
        let host = await mount(PaneMocks.done(exit: 0), store: store, width: 1280)
        defer { host.close() }

        // when
        host.resize(to: CGSize(width: 800, height: 700))
        await host.page.settle { topLevel(host) == ["Task details"] }

        // then
        #expect(host.hasPane)
        #expect(topLevel(host) == ["Task details"])
    }

    @Test(arguments: [("running", Int?.none), ("failed", 1), ("cancelled", nil), ("timed_out", nil)])
    func givenAnyStateButDone_whenFirstShownAtSplitWidth_thenThePaneIsClosed(status: String, exit: Int?) async {
        // given
        let mock = PaneMocks.done(exit: exit)
        var raw = mock.task!.raw
        raw["status"] = .string(status)
        mock.task = TaskInfo(.object(raw))

        // when
        let host = await mount(mock, store: TaskPaneStateStore(), width: 1280)
        defer { host.close() }

        // then
        #expect(!host.hasPane)
    }

    // MARK: - One pass across 900

    private struct Sample: Equatable {
        let paneVisible: Bool
        let overlay: Bool
    }

    private func sample(_ host: PaneHost) -> Sample {
        let top = topLevel(host)
        return Sample(paneVisible: host.hasPane, overlay: top == ["Task details"])
    }

    @Test func givenAnOpenPane_whenResizedAcrossNineHundred_thenTheModeSettlesInOnePassAndThePaneIsNeverRemounted() async throws {
        // given
        let host = await mount(PaneMocks.running(), store: seededStore(), width: 1000)
        defer { host.close() }
        let scroll = try #require(host.paneScrollViews().first)
        let identity = ObjectIdentifier(scroll)

        // when / then — down across, then up across, then within each side
        let steps: [(CGFloat, overlay: Bool)] = [(1000, false), (950, false), (899, true), (860, true), (900, false), (901, false), (700, true), (1400, false)]
        for (width, overlay) in steps {
            host.resize(to: CGSize(width: width, height: 700))
            var samples: [Sample] = []
            for _ in 0 ..< 20 {
                await host.pump(1)
                samples.append(sample(host))
            }
            var collapsed: [Sample] = []
            for value in samples where collapsed.last != value { collapsed.append(value) }
            #expect(collapsed.count <= 2, "width \(width) flickered through \(collapsed)")
            #expect(collapsed.last == Sample(paneVisible: true, overlay: overlay), "width \(width) settled on \(String(describing: collapsed.last))")
            #expect(host.paneScrollViews().first.map(ObjectIdentifier.init) == identity, "the pane was remounted at width \(width)")
        }
    }

    @Test func givenAnOpenPane_whenTheWidthChangesOnOneSideOfTheThreshold_thenTheModeNeverChanges() async {
        // given
        let host = await mount(PaneMocks.running(), store: seededStore(), width: 1000)
        defer { host.close() }

        // when / then
        for width in stride(from: 1000.0, through: 1500.0, by: 100.0) {
            host.resize(to: CGSize(width: width, height: 700))
            await host.page.settle { sample(host) == Sample(paneVisible: true, overlay: false) }
            #expect(sample(host) == Sample(paneVisible: true, overlay: false))
        }
        for width in stride(from: 880.0, through: 640.0, by: -60.0) {
            host.resize(to: CGSize(width: width, height: 700))
            await host.page.settle { sample(host) == Sample(paneVisible: true, overlay: true) }
            #expect(sample(host) == Sample(paneVisible: true, overlay: true))
        }
    }

    // MARK: - A then B then A

    @Observable @MainActor final class PaneSelection {
        var current = "A"
    }

    struct PaneSwitchHarness: View {
        let selection: PaneSelection
        let store: TaskPaneStateStore
        let mocks: [String: TaskDetailViewModelMock]

        var body: some View {
            let id = selection.current
            PaneMocks.standalone(mocks[id]!, store: store, conversation: id)
        }
    }

    @Test func givenTwoConversations_whenSelectingAThenBThenA_thenEachKeepsItsPaneStateAndEventsOffset() async throws {
        // given — A: Events with Task and the usage group expanded and a stored reading position; B: Artifacts.
        let store = TaskPaneStateStore()
        store.setOpenChoice(.open, for: "A")
        store.setSelectedTab(.events, for: "A")
        store.setExpandedGroups([.task, .usage], for: "A")
        store.setEventsScrollOffset(120, for: "A")
        store.setOpenChoice(.open, for: "B")
        store.setSelectedTab(.artifacts, for: "B")
        let selection = PaneSelection()
        let host = PaneHost(PaneSwitchHarness(selection: selection, store: store, mocks: ["A": PaneMocks.running(), "B": PaneMocks.running()]),
                            size: CGSize(width: 1280, height: 620))
        defer { host.close() }
        await host.page.settle { host.headerValue("Task") == "Expanded" && host.paneScrollViews().first != nil }

        // then — A restores its tab, groups and offset
        #expect(host.headerValue("Task") == "Expanded")
        #expect(host.headerValue("Reported result and usage") == "Expanded")
        let scroll = try #require(host.paneScrollViews().first)
        #expect(abs(scroll.contentView.bounds.origin.y - 120) <= 2, "restored offset \(scroll.contentView.bounds.origin.y)")

        // when — the person reads further, then selects B. The scroll is nudged on every pass until the pane has recorded
        // it, because recording only starts once the stored offset has been restored.
        var nudge = false
        await host.page.settle {
            nudge.toggle()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: nudge ? 200 : 199))
            scroll.reflectScrolledClipView(scroll.contentView)
            return store.eventsScrollOffset(for: "A").map { abs($0 - 200) <= 2 } == true
        }
        #expect(store.eventsScrollOffset(for: "A").map { abs($0 - 200) <= 2 } == true, "recorded \(String(describing: store.eventsScrollOffset(for: "A")))")
        selection.current = "B"
        await host.page.settle { host.hasPane && host.header("Task") == nil }

        // then — B has its own tab
        #expect(host.hasPane)
        #expect(host.header("Task") == nil)
        #expect(store.selectedTab(for: "B") == .artifacts)
        #expect(store.selectedTab(for: "A") == .events)

        // when — back to A
        selection.current = "A"
        await host.page.settle { host.headerValue("Task") == "Expanded" && host.headerValue("Reported result and usage") == "Expanded" }

        // then
        #expect(host.headerValue("Task") == "Expanded")
        #expect(host.headerValue("Reported result and usage") == "Expanded")
        let again = try #require(host.paneScrollViews().first)
        #expect(abs(again.contentView.bounds.origin.y - 200) <= 2, "offset after returning \(again.contentView.bounds.origin.y)")
        #expect(store.expandedGroups(for: "A") == [.task, .usage])
        #expect(store.expandedGroups(for: "B").isEmpty)
    }

    @Test func givenAClosedConversationAndAnOpenOne_whenSwitching_thenTheClosedStaysClosed() async {
        // given
        let store = TaskPaneStateStore()
        store.setOpenChoice(.open, for: "A")
        store.setOpenChoice(.closed, for: "B")
        let selection = PaneSelection()
        let host = PaneHost(PaneSwitchHarness(selection: selection, store: store, mocks: ["A": PaneMocks.running(), "B": PaneMocks.running()]),
                            size: CGSize(width: 1280, height: 620))
        defer { host.close() }
        await host.page.settle { host.hasPane }
        #expect(host.hasPane)

        // when / then
        selection.current = "B"
        await host.page.settle { !host.hasPane }
        #expect(!host.hasPane)
        selection.current = "A"
        await host.page.settle { host.hasPane }
        #expect(host.hasPane)
    }

    // MARK: - Reveal and Escape

    func activate(_ host: PaneHost) {
        _ = NSApplication.shared
        NSApp.activate(ignoringOtherApps: true)
        host.page.window.makeKey()
    }

}
