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
        let fixture = try await UnifiedSidebarHostFixture(sections: Self.scrollingSections())
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

        // when — the unified document scrolls navigation, Running and Recent work as one.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height))
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
        let fixture = try await UnifiedSidebarHostFixture(sections: Self.selectableSections())
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
        let fixture = try await UnifiedSidebarHostFixture(sections: Self.selectableSections())
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
        let fixture = try await UnifiedSidebarHostFixture(sections: Self.scrollingSections())
        defer { fixture.close() }
        var tasks = HistoryLoadingState()
        tasks.hasMore = true
        fixture.model.taskHistoryState = tasks
        await fixture.drain(cycles: 4)
        let outline = try #require(fixture.unifiedOutline)
        let scroll = try #require(outline.enclosingScrollView)
        let document = try #require(scroll.documentView)
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
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height))
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
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height))
        await fixture.drain(cycles: 4)
        await waitUntil(timeout: 5) { fixture.model.historyPublications.last?.visible == true }
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
    var installBannerModel: InstallBanner.Model?
    var needsYouBadge: NeedsYouBadge = .count(3, atLeast: false)
    var taskHistoryState = HistoryLoadingState()
    var workflowHistoryState = HistoryLoadingState()
    var historyPresentationRevision = 0

    private(set) var newSessionTapCount = 0
    private(set) var loadMoreTasksTapCount = 0
    private(set) var didSelectDestinations: [MonitorDestination?] = []
    private(set) var historyPublications: [(visible: Bool, revision: Int)] = []

    func didAppear() {}
    func didDisappear() {}
    func didChangeSearchQuery(_ text: String) { searchQuery = text }
    func didSelectBackendFilter(_ backend: String) { selectedBackend = backend }
    func didSelect(_ destination: MonitorDestination?) {
        selection = destination
        didSelectDestinations.append(destination)
    }

    func didTapNewSession() { newSessionTapCount += 1 }
    func didTapInstallBannerPrimary() {}
    func didTapInstallBannerSecondary() {}
    func didTapInstallBannerDismiss() {}
    func didToggleExpansion(taskID: String) {}
    func didPressMoveCommand(_ direction: MoveCommandDirection) {}
    func didTapLoadMoreTasks() { loadMoreTasksTapCount += 1 }
    func didChangeHistoryBottomVisibility(_ visible: Bool, revision: Int) {
        historyPublications.append((visible, revision))
    }
}

/// One production `SidebarView` in a real window; the unified outline is located by its reconciled
/// navigation, Running and Recent content, never by subview order.
@MainActor
private final class UnifiedSidebarHostFixture {
    let model: UnifiedSidebarHostedModel
    let host: NSHostingView<AnyView>
    let window: NSWindow

    init(sections: [SidebarSection]) async throws {
        // given
        _ = NSApplication.shared
        let model = UnifiedSidebarHostedModel()
        model.sections = sections
        self.model = model
        let root = AnyView(SidebarView(model).frame(width: 300, height: 480))
        self.host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
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
        window.contentView = nil
        window.close()
    }

    var unifiedOutline: NSOutlineView? {
        allOutlines.first { outline in
            let ids = Set((0 ..< outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id })
            return ids.contains("navigation:new-task") && ids.contains("header:running") && ids.contains("header:recent")
        }
    }

    var allOutlines: [NSOutlineView] { allViews.compactMap { $0 as? NSOutlineView } }
    var allScrollViews: [NSScrollView] { allViews.compactMap { $0 as? NSScrollView } }

    private var allViews: [NSView] {
        var views: [NSView] = []
        var queue: [NSView] = [host]
        while let view = queue.popLast() {
            views.append(view)
            queue.append(contentsOf: view.subviews)
        }
        return views
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
