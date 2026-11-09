import AppKit
import HfCommon
import HfRepository
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

/// M04 `.hd-m04-sidebar-scroll`, hosted: one bounded native outline scrolls navigation, Running and
/// Recent work under the fixed brand header and the fixed appearance/Settings footer, with native
/// keyboard selection crossing every section, New task dispatching the composer request, Needs you
/// normalizing to its single row, and revision-qualified history admission at — and only at —
/// the unified bottom sentinel.
@MainActor
@Suite(.serialized)
struct SidebarUnifiedHostedTests {
    @Test func givenUnifiedSidebar_whenHosted_thenOneBoundedOutlineScrollsUnderFixedChrome() async throws {
        // given
        let fixture = try await UnifiedSidebarHostFixture(sections: Self.scrollingSections(), witnessName: "bounded-scroll")
        defer { fixture.close() }
        await fixture.drain(cycles: 4)
        // when
        let outline = try #require(fixture.unifiedOutline)
        let scroll = try #require(outline.enclosingScrollView)
        // then — production exposes exactly one outline and one owned scroll view.
        #expect(fixture.allOutlines.count == 1)
        #expect(fixture.allScrollViews.count == 1)
        #expect(scroll.scrollerStyle == .overlay)
        #expect(scroll.verticalScroller?.controlSize == .small)
        #expect(scroll.hasVerticalScroller)
        let ids = fixture.entryIDs
        #expect(Array(ids.prefix(5)) == ["navigation:new-task", "navigation:needs-you", "navigation:workflows",
                                        "navigation:resources", "navigation:statistics"])
        #expect(ids.contains("header:running") && ids.contains("header:recent"))
        #expect(ids.filter { $0 == "history:sentinel" }.count == 1)
        #expect(ids.last == "history:sentinel")
        if let needsYouRow = fixture.row(for: "navigation:needs-you"),
           let box = outline.item(atRow: needsYouRow) as? SidebarNativeItemBox,
           case .navigation(let navigation) = box.entry.content {
            #expect(navigation.badge.capsuleText == "3")
        } else {
            #expect(Bool(false), "The unified list must carry the Needs you navigation entry")
        }
        // The fixed header and footer bound the scroll view on both sides.
        let document = try #require(scroll.documentView)
        let scrollFrame = scroll.convert(scroll.bounds, to: fixture.host)
        #expect(scrollFrame.minY > 0)
        #expect(scrollFrame.maxY < fixture.host.bounds.height - 1)
        #expect(document.bounds.height > scroll.contentView.bounds.height + 1)

        // when — the unified document scrolls navigation, Running and Recent work as one,
        // bounded by the clip view's own constrained origin: never an overscroll past the
        // document, with the sentinel revealed through the native row reveal.
        await fixture.scrollToSettledUnifiedBottom()
        await fixture.drain(cycles: 4)
        let viewport = outline.convert(scroll.contentView.bounds, from: scroll.contentView)
        let runningRow = try #require(fixture.row(for: "header:running"))
        let runningRect = outline.rect(ofRow: runningRow)
        let sentinelRow = try #require(fixture.row(for: "history:sentinel"))
        let sentinelRect = outline.rect(ofRow: sentinelRow)
        // then — the Running heading scrolled away with the navigation, the sentinel marks the
        // bottom, and the fixed chrome did not move.
        #expect(runningRect.maxY < viewport.minY)
        #expect(sentinelRect.maxY >= viewport.minY && sentinelRect.minY <= viewport.maxY)
        let scrolledFrame = scroll.convert(scroll.bounds, to: fixture.host)
        #expect(abs(scrolledFrame.minY - scrollFrame.minY) <= 1)
        #expect(abs(scrolledFrame.maxY - scrollFrame.maxY) <= 1)
    }

    @Test func givenUnifiedOutline_whenSelectionMovesAcrossSections_thenDispatchAndHighlightStayAtomic() async throws {
        // given
        let fixture = try await UnifiedSidebarHostFixture(sections: Self.selectableSections(), witnessName: "selection")
        defer { fixture.close() }
        await fixture.drain(cycles: 4)
        let outline = try #require(fixture.unifiedOutline)
        let coordinator = try #require(outline.delegate as? SidebarNativeList.Coordinator)
        let scroll = try #require(outline.enclosingScrollView)
        fixture.window.makeFirstResponder(outline)
        await fixture.drain(cycles: 2)

        // when — New task is selected through the native path.
        let newRow = try #require(fixture.row(for: "navigation:new-task"))
        outline.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
        await waitUntil(timeout: 5) { fixture.model.newSessionTapCount == 1 }
        // then — New task is the composer request, never a destination selection.
        #expect(fixture.model.newSessionTapCount == 1)
        #expect(fixture.model.selection == nil)
        #expect(fixture.model.didSelectDestinations.isEmpty)

        // when — keyboard selection walks Statistics down through Running into Recent work.
        let statisticsRow = try #require(fixture.row(for: "navigation:statistics"))
        outline.selectRowIndexes(IndexSet(integer: statisticsRow), byExtendingSelection: false)
        await waitUntil(timeout: 5) {
            outline.selectedRowIndexes == IndexSet(integer: statisticsRow)
                && fixture.model.selection == .statistics
        }
        await fixture.drain(cycles: 2)
        try await fixture.pressDown()
        await waitUntil(timeout: 5) {
            fixture.model.selection == .task("run-a")
                && outline.selectedRowIndexes.count == 1
                && outline.selectedRowIndexes.first == fixture.row(for: "task:run-a")
        }
        try await fixture.pressDown()
        await waitUntil(timeout: 5) {
            fixture.model.selection == .task("today-a")
                && outline.selectedRowIndexes.count == 1
                && outline.selectedRowIndexes.first == fixture.row(for: "task:today-a")
        }
        // then — exactly one atomic selection surface across every section.
        #expect(outline.selectedRowIndexes.count == 1)
        #expect(coordinator.lastHostedSelectedIDs.count == 1)
        #expect(coordinator.destinationIndexes[.task("today-a")]?.count == 1)
        #expect(try fixture.cellSelectedFlags(for: ["navigation:statistics", "task:run-a"]) == [false, false])
        #expect(try fixture.cellSelectedFlags(for: ["task:today-a"]) == [true])
    }

    @Test func givenNeedsYouSelectionWithItemID_whenHosted_thenSingleNormalizedRowHighlights() async throws {
        // given
        let fixture = try await UnifiedSidebarHostFixture(sections: Self.selectableSections(), witnessName: "needs-you")
        defer { fixture.close() }
        await fixture.drain(cycles: 4)
        let outline = try #require(fixture.unifiedOutline)
        let needsYouRow = try #require(fixture.row(for: "navigation:needs-you"))
        // when — a Needs you request id from outside normalizes onto the one navigation row.
        fixture.model.selection = .needsYou(itemID: "stale-request")
        await waitUntil(timeout: 5) {
            outline.selectedRowIndexes == IndexSet(integer: needsYouRow)
        }
        // then
        #expect(fixture.entryID(at: needsYouRow) == "navigation:needs-you")
        #expect(try fixture.cellSelectedFlags(for: ["navigation:needs-you", "navigation:statistics"]) == [true, false])
    }

    @Test func givenOverflowingHistory_whenBottomIsOffscreen_thenAdmissionIsRevisionQualified() async throws {
        // given
        let fixture = try await UnifiedSidebarHostFixture(sections: Self.scrollingSections(), witnessName: "revision-qualified")
        defer { fixture.close() }
        var tasks = HistoryLoadingState()
        tasks.hasMore = true
        fixture.model.taskHistoryState = tasks
        await fixture.drain(cycles: 4)
        let outline = try #require(fixture.unifiedOutline)
        let scroll = try #require(outline.enclosingScrollView)
        _ = try #require(fixture.row(for: "history:tasks"))
        _ = try #require(fixture.row(for: "history:sentinel"))
        // when — the bottom is offscreen at the document top.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        await fixture.drain(cycles: 4)
        await waitUntil(timeout: 5) { !fixture.model.historyPublications.isEmpty }
        // then — no admission while the sentinel is offscreen.
        #expect(fixture.model.historyPublications.allSatisfy { !$0.visible })
        #expect(fixture.model.loadMoreTasksTapCount == 0)

        // when — the unified bottom scrolls into view.
        await fixture.scrollToSettledUnifiedBottom()
        await fixture.drain(cycles: 4)
        await waitUntil(timeout: 5) { fixture.model.historyPublications.last?.visible == true }
        // then — admission carries the current revision.
        #expect(fixture.model.historyPublications.last?.revision == 0)

        // when — the revision advances while the bottom stays visible.
        fixture.model.historyPresentationRevision += 1
        await fixture.drain(cycles: 4)
        await waitUntil(timeout: 5) { fixture.model.historyPublications.last?.revision == 1 }
        #expect(fixture.model.historyPublications.last?.visible == true)

        // when — the bottom scrolls away, then returns.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        await fixture.drain(cycles: 4)
        await waitUntil(timeout: 5) { fixture.model.historyPublications.last?.visible == false }
        #expect(fixture.model.historyPublications.last?.visible == false)
        fixture.scrollToUnifiedBottom()
        await fixture.drain(cycles: 4)
        await waitUntil(timeout: 5) { fixture.model.historyPublications.last?.visible == true }
        #expect(fixture.model.historyPublications.last?.visible == true)
        // then — visibility flips are recorded at the bottom revision, never a stale one.
        #expect(fixture.model.historyPublications.last?.revision == 1)
        #expect(fixture.model.historyPublications.filter(\.visible).allSatisfy { $0.revision <= 1 })
    }

    // MARK: - Fixtures

    private static func scrollingSections() -> [SidebarSection] {
        let earlier = (0 ..< 40).map { index in
            SidebarItem.task(TaskRowModel(
                id: "earlier-\(index)", backend: "codex", title: "Earlier row \(index)",
                status: .completed, repoName: "repo", ageText: "1d", indent: 0
            ))
        }
        return [
            SidebarSection(bucket: .running, items: [Self.task("run-a")]),
            SidebarSection(bucket: .today, items: [Self.task("today-a")]),
            SidebarSection(bucket: .earlier, items: earlier)
        ]
    }

    private static func selectableSections() -> [SidebarSection] {
        [
            SidebarSection(bucket: .running, items: [task("run-a")]),
            SidebarSection(bucket: .today, items: [task("today-a")])
        ]
    }

    private static func task(_ id: String) -> SidebarItem {
        .task(TaskRowModel(id: id, backend: "codex", title: id, status: .completed,
                           repoName: "repo", ageText: "1h", indent: 0))
    }
}

// MARK: - Hosted model and fixture

/// One history publication observed at publication time, on the main actor: the admitted
/// visibility and revision next to the geometry and reconciler state that produced them.
/// `nil` fields mean the corresponding state was not yet reachable at publication time.
private struct HistoryPublicationWitness {
    let visible: Bool
    let revision: Int
    let sentinelRect: String?
    let viewportRect: String?
    /// The reconciler's actual column width (`availableWidth`), not the clip view's bounds.
    let availableWidth: CGFloat?
    /// The scroll clip view's own bounds width, recorded separately from `availableWidth`.
    let clipWidth: CGFloat?
    let knownWidth: CGFloat?
    let inputHistoryRevision: Int?
    let inputHistoryToken: String?
    let appliedHistoryRevision: Int?
    let appliedHistoryToken: String?
    let generation: Int?
    let settledGeneration: Int?
    let widthInvalidationQueued: Bool?
    let nativeOperationDepth: Int?
    let windowAttached: Bool?
    let windowVisible: Bool?
    let outlineNeedsLayout: Bool?
    let applyingStructure: Bool?
    let pendingHeights: Int?
}

/// A recording SidebarViewModel: selections, composer dispatches and history admissions are
/// observable on the main actor without touching the preview mock outside this file.
@MainActor
@Observable
private final class UnifiedSidebarHostedModel: SidebarViewModel {
    var sections: [SidebarSection] = []
    var listErrorMessage: String?
    var emptyStateMessage: String?
    var showsLoadingSkeleton = false
    var isConnected = true
    var connectionLine = "connected · harflow-ctl"
    var backendTabs: [BackendTab] = [.all]
    var selectedBackend = "all"
    var catalogUnavailableNote: String?
    var searchQuery = ""
    var selection: MonitorDestination?
    var needsYouBadge: NeedsYouBadge = .count(3, atLeast: false)
    var taskHistoryState = HistoryLoadingState()
    var workflowHistoryState = HistoryLoadingState()
    var historyPresentationRevision = 0

    private(set) var newSessionTapCount = 0
    private(set) var loadMoreTasksTapCount = 0
    private(set) var didSelectDestinations: [MonitorDestination?] = []
    private(set) var historyPublications: [(visible: Bool, revision: Int)] = []
    /// Test-only publication-time witness for every history callback: the fixture installs the
    /// recorder before its window gains content, so initial publications are retained, never
    /// cleared or hidden. Recorded facts never gate the existing history assertions.
    var historyWitnessRecorder: (@MainActor (_ visible: Bool, _ revision: Int) -> HistoryPublicationWitness)?
    private(set) var historyWitnesses: [HistoryPublicationWitness] = []
    let presentationEvidence = SidebarHistoryPresentationEvidence()

    func didAppear() {}
    func didDisappear() {}
    func didChangeSearchQuery(_ text: String) { searchQuery = text }
    func didSelectBackendFilter(_ backend: String) { selectedBackend = backend }
    func didSelect(_ destination: MonitorDestination?) {
        selection = destination
        didSelectDestinations.append(destination)
    }

    func didTapNewSession() { newSessionTapCount += 1 }
    func didToggleExpansion(taskID: String) {}
    func didPressMoveCommand(_ direction: MoveCommandDirection) {}
    func didTapLoadMoreTasks() { loadMoreTasksTapCount += 1 }
    func didChangeHistoryBottomVisibility(_ visible: Bool, revision: Int) {
        historyPublications.append((visible, revision))
        if let record = historyWitnessRecorder?(visible, revision) {
            historyWitnesses.append(record)
        }
    }
}

/// One production `SidebarView` in a real window; the unified outline is located by its reconciled
/// navigation, Running and Recent content, never by subview order.
@MainActor
private final class UnifiedSidebarHostFixture {
    let model: UnifiedSidebarHostedModel
    let host: NSHostingView<AnyView>
    let window: NSWindow
    let witnessName: String

    init(sections: [SidebarSection], witnessName: String) async throws {
        // given
        _ = NSApplication.shared
        let model = UnifiedSidebarHostedModel()
        model.sections = sections
        self.model = model
        self.witnessName = witnessName
        let root = AnyView(SidebarView(model).frame(width: 300, height: 480))
        let host = NSHostingView(rootView: root)
        self.host = host
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        // The publication-time witness is installed before the window gains content and is
        // ordered front, so the initial history publications are recorded, never swallowed.
        model.historyWitnessRecorder = { [weak host, weak model] visible, revision in
            if let host, let outline = Self.unifiedOutline(in: host),
               let coordinator = outline.delegate as? SidebarNativeList.Coordinator {
                coordinator.historyGeometryObserved = { [weak coordinator, weak model] rawVisible in
                    guard let coordinator, let model else { return }
                    model.presentationEvidence.record(rawVisible: rawVisible, coordinator: coordinator)
                }
            }
            return Self.captureHistoryWitness(visible: visible, revision: revision, host: host)
        }
        window.contentView = host
        window.orderFront(nil)
        self.window = window
        // when — the unified list must settle its own reconciliation before assertions run.
        await waitUntil(timeout: 5) {
            self.host.layoutSubtreeIfNeeded()
            guard let outline = self.unifiedOutline else { return false }
            return outline.numberOfRows > 0
                && Set(self.entryIDs).isSuperset(of: ["history:sentinel"])
        }
    }

    func close() {
        model.presentationEvidence.write(name: witnessName)
        captureHistoryWitnessJSON()
        window.contentView = nil
        window.close()
    }

    var unifiedOutline: NSOutlineView? { Self.unifiedOutline(in: host) }

    var allOutlines: [NSOutlineView] { Self.allViews(of: host).compactMap { $0 as? NSOutlineView } }
    var allScrollViews: [NSScrollView] { Self.allViews(of: host).compactMap { $0 as? NSScrollView } }

    private static func allViews(of root: NSView) -> [NSView] {
        var views: [NSView] = []
        var queue: [NSView] = [root]
        while let view = queue.popLast() {
            views.append(view)
            queue.append(contentsOf: view.subviews)
        }
        return views
    }

    private static func unifiedOutline(in view: NSView) -> NSOutlineView? {
        allViews(of: view).compactMap { $0 as? NSOutlineView }.first { outline in
            let ids = Set((0 ..< outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id })
            return ids.contains("navigation:new-task") && ids.contains("header:running") && ids.contains("header:recent")
        }
    }

    /// Scrolls the unified document to its bottom the way the clip view itself bounds it: the
    /// constrained maximum origin — never an overscroll past the document — followed by the
    /// native sentinel row reveal and the clip view's own scrolled-position reflection.
    func scrollToUnifiedBottom() {
        guard let outline = unifiedOutline, let scroll = outline.enclosingScrollView,
              let document = scroll.documentView else { return }
        let maximumOriginY = max(0, document.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: maximumOriginY))
        if let sentinelRow = row(for: "history:sentinel") { outline.scrollRowToVisible(sentinelRow) }
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// True when the reconciler has no unsettled presentation, no pending height and no queued
    /// width invalidation: the document height is final for the current content.
    private var isGeometrySettled: Bool {
        guard let outline = unifiedOutline, let coordinator = outline.delegate as? SidebarNativeList.Coordinator else { return false }
        return !coordinator.hasUnsettledPresentations && coordinator.pendingHeights.isEmpty && !coordinator.widthInvalidationQueued
    }

    private var sentinelIntersectsViewport: Bool {
        guard let outline = unifiedOutline, let scroll = outline.enclosingScrollView,
              let sentinelRow = row(for: "history:sentinel") else { return false }
        let viewport = outline.convert(scroll.contentView.bounds, from: scroll.contentView)
        let sentinelRect = outline.rect(ofRow: sentinelRow)
        return sentinelRect.maxY >= viewport.minY && sentinelRect.minY <= viewport.maxY
    }

    /// Waits for settled geometry on two consecutive polls, pumping layout and display directly
    /// in each poll. Returns whether the document settled within the bound.
    private func waitForSettledGeometry() async -> Bool {
        var consecutive = 0
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            consecutive = isGeometrySettled ? consecutive + 1 : 0
            return consecutive >= 2
        }
        return consecutive >= 2
    }

    /// Settles the document, scrolls to its bottom exactly once, then waits without scrolling
    /// again for the sentinel to be in the viewport on settled geometry. The outcome is asserted
    /// here because `waitUntil` does not report a timeout.
    func scrollToSettledUnifiedBottom() async {
        let settledBefore = await waitForSettledGeometry()
        #expect(settledBefore, "The unified document must settle before scrolling")
        scrollToUnifiedBottom()
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            return sentinelIntersectsViewport && isGeometrySettled
        }
        #expect(sentinelIntersectsViewport, "One scroll on a settled document must reach the sentinel")
        #expect(isGeometrySettled, "The document must remain settled after the scroll")
    }

    /// Captures one history publication where it happens, reading only public state from this
    /// fixture's own hosted tree and its reconciler: sentinel and viewport geometry, the
    /// reconciler's actual and known widths, the input and applied history revisions/tokens,
    /// its generation, width-invalidation and native-operation state, and the outline's own
    /// attachment/layout state. Nothing is invoked or mutated.
    private static func captureHistoryWitness(visible: Bool, revision: Int, host: NSView?) -> HistoryPublicationWitness {
        func empty() -> HistoryPublicationWitness {
            HistoryPublicationWitness(visible: visible, revision: revision, sentinelRect: nil, viewportRect: nil,
                                      availableWidth: nil, clipWidth: nil, knownWidth: nil, inputHistoryRevision: nil,
                                      inputHistoryToken: nil, appliedHistoryRevision: nil, appliedHistoryToken: nil,
                                      generation: nil, settledGeneration: nil, widthInvalidationQueued: nil,
                                      nativeOperationDepth: nil, windowAttached: nil, windowVisible: nil,
                                      outlineNeedsLayout: nil, applyingStructure: nil, pendingHeights: nil)
        }
        guard let host, let outline = unifiedOutline(in: host) else { return empty() }
        let scroll = outline.enclosingScrollView
        let coordinator = outline.delegate as? SidebarNativeList.Coordinator
        let sentinelRect = (0 ..< outline.numberOfRows)
            .first { (outline.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id == "history:sentinel" }
            .map { NSStringFromRect(outline.rect(ofRow: $0)) }
        let viewportRect = scroll.map { NSStringFromRect(outline.convert($0.contentView.bounds, from: $0.contentView)) }
        return HistoryPublicationWitness(
            visible: visible,
            revision: revision,
            sentinelRect: sentinelRect,
            viewportRect: viewportRect,
            availableWidth: coordinator?.availableWidth,
            clipWidth: scroll?.contentView.bounds.width,
            knownWidth: coordinator?.knownWidth,
            inputHistoryRevision: coordinator?.input?.historyRevision,
            inputHistoryToken: coordinator?.input?.historyToken,
            appliedHistoryRevision: coordinator?.appliedInput?.historyRevision,
            appliedHistoryToken: coordinator?.appliedInput?.historyToken,
            generation: coordinator?.generation,
            settledGeneration: coordinator?.settledGeneration,
            widthInvalidationQueued: coordinator?.widthInvalidationQueued,
            nativeOperationDepth: coordinator?.nativeOperationDepth,
            windowAttached: outline.window != nil,
            windowVisible: outline.window?.isVisible,
            outlineNeedsLayout: outline.needsLayout,
            applyingStructure: coordinator?.applyingStructure,
            pendingHeights: coordinator?.pendingHeights.count
        )
    }

    /// Optional bounded JSON under the existing M04 capture directory, for primary diagnosis
    /// only: this fixture's own witness records, truncated at the bound. It never gates or
    /// clears the recorded history.
    private func captureHistoryWitnessJSON() {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_M04_CAPTURE_DIR"], !output.isEmpty else { return }
        let records = model.historyWitnesses
        let prefixBound = 64
        let suffixBound = 128
        let selected: [HistoryPublicationWitness] = if records.count > prefixBound + suffixBound {
            Array(records.prefix(prefixBound)) + Array(records.suffix(suffixBound))
        } else {
            records
        }
        var witnesses: [[String: Any]] = []
        for record in selected {
            var entry: [String: Any] = ["visible": record.visible, "revision": record.revision]
            entry["sentinelRect"] = record.sentinelRect
            entry["viewportRect"] = record.viewportRect
            entry["availableWidth"] = record.availableWidth.map { NSNumber(value: Double($0)) }
            entry["clipWidth"] = record.clipWidth.map { NSNumber(value: Double($0)) }
            entry["knownWidth"] = record.knownWidth.map { NSNumber(value: Double($0)) }
            entry["inputHistoryRevision"] = record.inputHistoryRevision
            entry["inputHistoryToken"] = record.inputHistoryToken
            entry["appliedHistoryRevision"] = record.appliedHistoryRevision
            entry["appliedHistoryToken"] = record.appliedHistoryToken
            entry["generation"] = record.generation
            entry["settledGeneration"] = record.settledGeneration
            entry["widthInvalidationQueued"] = record.widthInvalidationQueued
            entry["nativeOperationDepth"] = record.nativeOperationDepth
            entry["windowAttached"] = record.windowAttached
            entry["windowVisible"] = record.windowVisible
            entry["outlineNeedsLayout"] = record.outlineNeedsLayout
            entry["applyingStructure"] = record.applyingStructure
            entry["pendingHeights"] = record.pendingHeights
            witnesses.append(entry)
        }
        let payload: [String: Any] = [
            "fixture": witnessName,
            "totalWitnesses": records.count,
            "truncated": selected.count < records.count,
            "witnesses": witnesses
        ] as [String: Any]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]) {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent("sidebar-unified-history-witness-\(witnessName).json"))
        }
    }

    var entryIDs: [String] {
        guard let outline = unifiedOutline else { return [] }
        return (0 ..< outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id }
    }

    func entryID(at row: Int) -> String? {
        guard let outline = unifiedOutline, let box = outline.item(atRow: row) as? SidebarNativeItemBox else { return nil }
        return box.entry.id
    }

    func row(for id: String) -> Int? {
        guard let outline = unifiedOutline else { return nil }
        return (0 ..< outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id == id }
    }

    func cellSelectedFlags(for ids: [String]) throws -> [Bool] {
        let outline = try #require(unifiedOutline)
        return ids.map { id in
            guard let row = row(for: id),
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarNativeCell
            else { return false }
            return cell.host?.rootView.selected == true
        }
    }

    func pressDown() async throws {
        let outline = try #require(unifiedOutline)
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil,
                                    characters: String(UnicodeScalar(0xF701)!),
                                    charactersIgnoringModifiers: String(UnicodeScalar(0xF701)!),
                                    isARepeat: false, keyCode: 125)
        if let down { outline.keyDown(with: down) }
        await drain(cycles: 2)
    }

    func drain(cycles: Int) async {
        var completed = 0
        await waitUntil(timeout: 1) {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            completed += 1
            return completed >= cycles
        }
    }
}
