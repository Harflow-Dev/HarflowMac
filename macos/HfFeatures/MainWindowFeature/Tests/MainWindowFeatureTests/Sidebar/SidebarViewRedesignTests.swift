//
//  SidebarViewRedesignTests.swift
//  MainWindowFeatureTests
//
//  Phase 1's focused sidebar render tests (SPEC §§4, 6.1): the moved New session control and its
//  display-only ⌘N hint, the compact backend-dot filter's visible selected name and VoiceOver
//  value, the history surface's exhaustion/loading/error/hasMore states, and the alias `selectedRow`
//  fill's row geometry. These host the real `SidebarView`, like the selection tests beside them.
//

import AppKit
import HfCommon
import HfRepository
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct SidebarViewRedesignTests {

    // MARK: - Helpers

    private func present(
        _ vm: SidebarViewModelMock,
        outlineRole: SidebarListPresentation.Role = .recent
    ) async throws -> (host: NSHostingView<AnyView>, window: NSWindow) {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        // Activate SwiftUI's accessibility descriptors only in this test application's process.
        let host = NSHostingView(rootView: AnyView(SidebarView(vm).frame(width: HfRadius.Metrics.sidebarPreviewWidth,
                                                                      height: HfRadius.Metrics.sidebarTallFixtureHeight)))
        let window = NSWindow(contentRect: CGRect(x: HfRadius.Metrics.zero, y: HfRadius.Metrics.zero,
                                                 width: HfRadius.Metrics.sidebarPreviewWidth, height: HfRadius.Metrics.sidebarTallFixtureHeight),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        await waitUntil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            host.layoutSubtreeIfNeeded()
            return (sidebarUnifiedFixtureOutline(in: host)?.numberOfRows ?? 0) > 0
        }
        await waitUntil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            guard let outline = outlineView(host, role: outlineRole) else { return false }
            guard let coordinator = outline.delegate as? SidebarNativeList.Coordinator else { return false }
            return !coordinator.hasUnsettledPresentations && coordinator.pendingHostedHeights.isEmpty
                && coordinator.pendingHeights.isEmpty && coordinator.reconciliation == nil
        }
        return (host, window)
    }

    private func release(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func outlineView(_ host: NSView, role: SidebarListPresentation.Role = .recent) -> NSOutlineView? {
        sidebarUnifiedFixtureOutline(in: host)
    }

    /// The hosted accessibility tree: the AppKit subviews plus the platform elements SwiftUI
    /// exposes through `accessibilityChildren`, recursively.
    private func accessibilityElements(_ view: NSView) -> [NSObject] {
        var found: [NSObject] = []
        for subview in view.subviews { found += accessibilityElements(subview) }
        found += accessibilityTree(view)
        return found
    }

    private func accessibilityTree(_ element: NSObject) -> [NSObject] {
        var result = [element]
        let children = NSSelectorFromString("accessibilityChildren")
        guard element.responds(to: children),
              let raw = element.perform(children)?.takeUnretainedValue() as? [Any]
        else { return result }
        for child in raw {
            if let object = child as? NSObject { result += accessibilityTree(object) }
        }
        return result
    }

    private func accessibilityString(_ element: NSObject, _ name: String) -> String? {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue() as? String
    }

    private func elements(labelled label: String, in host: NSView) -> [NSObject] {
        accessibilityElements(host).filter {
            accessibilityString($0, "accessibilityLabel") == label
                || accessibilityString($0, "accessibilityTitle") == label
                || accessibilityString($0, "accessibilityValue") == label
        }
    }

    @discardableResult
    private func press(_ element: NSObject) -> Bool {
        if let accessible = element as? any NSAccessibilityProtocol {
            return accessible.accessibilityPerformPress()
        }
        // SwiftUI's virtual AccessibilityNode implements the method without declaring the
        // AppKit protocol. Invoke its exact scalar-return ABI, never NSObject.perform's object ABI.
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard element.responds(to: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = unsafeBitCast(element.method(for: selector), to: Press.self)
        return implementation(element, selector)
    }

    /// The element's frame in window coordinates (accessibility frames are screen coordinates).
    private func frameInWindow(_ element: NSObject, window: NSWindow) -> CGRect? {
        if let accessible = element as? any NSAccessibilityProtocol {
            return window.convertFromScreen(accessible.accessibilityFrame())
        }
        // KVC boxes the CGRect returned by SwiftUI's virtual node as NSValue safely.
        guard element.responds(to: NSSelectorFromString("accessibilityFrame")),
              let frame = element.value(forKey: "accessibilityFrame") as? NSValue else { return nil }
        return window.convertFromScreen(frame.rectValue)
    }

    private func rowHeight(_ outline: NSOutlineView, _ row: Int) -> CGFloat {
        outline.rect(ofRow: row).height
    }

    private func settledNativeRows(_ outline: NSOutlineView) -> Bool {
        guard let coordinator = outline.delegate as? SidebarNativeList.Coordinator else { return false }
        return coordinator.reconciliation == nil
            && coordinator.detached == nil
            && coordinator.pendingInput == nil
            && coordinator.settledGeneration == coordinator.generation
            && coordinator.boxesByID.values.allSatisfy { !$0.entry.isFading }
    }

    /// The outline's content rows — the rows the sidebar's own selection tests drive, i.e. the
    /// tagged task/group/workflow rows, never section headers or untagged surfaces.
    private func contentRows(_ outline: NSOutlineView) -> [Int] {
        (0 ..< outline.numberOfRows).filter { row in
            let item = outline.item(atRow: row) as Any
            guard let box = item as? SidebarNativeItemBox else { return false }
            guard case .item = box.entry.content else { return false }
            return outline.delegate?.outlineView?(outline, shouldSelectItem: item) == true
        }
    }

    // MARK: - New session (moved action)

    @Test func givenTheSidebar_whenRendered_thenNewTaskSharesTheBodyAndCallsTheExistingAction() async throws {
        // given
        let vm = SidebarViewModelMock()
        let sut = try await present(vm)
        defer { release(sut.window) }

        // when / then — New task is the first row in the approved shared scroll body.
        let button = try #require(elements(labelled: "New task", in: sut.host).first, "The New session control must be present")
        let outline = try #require(outlineView(sut.host))
        let buttonFrame = try #require(frameInWindow(button, window: sut.window))
        let outlineFrame = outline.convert(outline.bounds, to: nil)
        #expect(outlineFrame.contains(buttonFrame), "New task must belong to the shared observation surface")
        #expect(buttonFrame.maxY <= sut.window.contentLayoutRect.maxY + 0.5)
        #expect(!descendants(sut.host).compactMap { $0 as? NSTextField }.contains { $0.placeholderString == "Search loaded history" })

        // The retained plain label, with the display-only hint hidden from VoiceOver.
        #expect(!accessibilityElements(sut.host).contains { accessibilityString($0, "accessibilityLabel")?.contains("⌘N") == true },
                "The ⌘N hint is display-only and must stay hidden from VoiceOver")

        // when — pressed, it performs today's action exactly.
        let rowIDs = (0 ..< outline.numberOfRows).compactMap {
            (outline.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id
        }
        #expect(rowIDs.first == "navigation:new-task")
        let selectionBefore = vm.selection
        let accessibleRows = try #require((outline as any NSAccessibilityProtocol).accessibilityRows())
        #expect(accessibleRows.count == outline.numberOfRows)
        let newTaskRow = try #require(accessibleRows.first)
        (outline as any NSAccessibilityProtocol).setAccessibilitySelectedRows([newTaskRow])
        await waitUntil { vm.newSessionTapCount == 1 }

        // then
        #expect(vm.newSessionTapCount == 1)
        #expect(vm.selection == selectionBefore)
        #expect((0 ..< outline.numberOfRows).compactMap {
            (outline.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id
        } == rowIDs)
    }

    @Test func givenInstallBannerModel_whenReadySidebarRenders_thenNoNoticeIsDrawn() async throws {
        // given — the sidebar no longer renders the install notice.
        let vm = SidebarViewModelMock(installBannerModel: .init(title: "Runtime installed", detail: "Ready for sessions", canDismiss: true))
        let sut = try await present(vm)
        defer { release(sut.window) }

        // when / then
        #expect(elements(labelled: "Runtime installed", in: sut.host).isEmpty)
        #expect(elements(labelled: "Ready for sessions", in: sut.host).isEmpty)
        #expect(!accessibilityElements(sut.host).contains {
            accessibilityString($0, "accessibilityIdentifier") == "sidebar-install-notice"
        })
        #expect(sidebarFixtureOutline(in: sut.host) != nil)
    }

    @Test func givenStoreNeedsAttention_whenReadySidebarRenders_thenTheLinkSitsBelowTheTitleRow() async throws {
        // given
        let vm = SidebarViewModelMock()
        vm.storeNeedsAttention = true
        let sut = try await present(vm)
        defer { release(sut.window) }

        // when
        let title = try #require(elements(labelled: "Harflow", in: sut.host).first)
        let link = try #require(accessibilityElements(sut.host).first {
            accessibilityString($0, "accessibilityIdentifier") == "sidebar-store-attention"
        })
        let titleFrame = try #require(frameInWindow(title, window: sut.window))
        let linkFrame = try #require(frameInWindow(link, window: sut.window))

        // then — window coordinates grow upward: the title row is topmost, the link is below it.
        #expect(titleFrame.minY >= linkFrame.maxY - 0.5)
        #expect(sidebarFixtureOutline(in: sut.host) != nil)
    }

    // MARK: - Backend filter

    @Test func givenSelectedBackend_whenRendered_thenRemovedFilterIsAbsentAndHistoryRemainsAvailable() async throws {
        // given
        let vm = SidebarViewModelMock(selectedBackend: "claude")
        let sut = try await present(vm)
        defer { release(sut.window) }
        // when / then
        #expect(elements(labelled: "Harness filter", in: sut.host).isEmpty)
        #expect(sidebarFixtureOutline(in: sut.host) != nil)
        #expect(!descendants(sut.host).compactMap { $0 as? NSTextField }.contains { $0.placeholderString == "Search loaded history" })
    }

    @Test func givenADegradedCatalog_whenRendered_thenTheNoteStaysWithTheFilter() async throws {
        // given
        let note = "The backend catalog couldn't be read; filters show loaded history only."
        let sut = try await present(SidebarViewModelMock(sections: [], emptyStateMessage: "No claude tasks yet.", catalogUnavailableNote: note))
        defer { release(sut.window) }

        // when / then — the same diagnostic, beside the same filter choices.
        #expect(!elements(labelled: note, in: sut.host).isEmpty)
    }

    @Test(arguments: [5, 40])
    func givenAFullBackendCatalog_whenRenderedAtMinimumWidth_thenNavigationFitsWithoutRemovedControls(count: Int) async throws {
        // given
        let tabs = [BackendTab.all] + (0 ..< count).map { BackendTab(id: "backend-\($0)", isNotFound: false) }
        let sut = try await present(SidebarViewModelMock(backendTabs: tabs))
        defer { release(sut.window) }

        // when / then — catalog size cannot restore removed controls or crowd navigation.
        #expect(elements(labelled: "Harness filter", in: sut.host).isEmpty)
        #expect(!descendants(sut.host).compactMap { $0 as? NSTextField }.contains { $0.placeholderString == "Search loaded history" })
        for title in ["New task", "Workflows", "Resources", "Statistics"] {
            let element = try #require(elements(labelled: title, in: sut.host).first)
            let frame = try #require(frameInWindow(element, window: sut.window))
            #expect(frame.minX >= 0)
            #expect(frame.maxX <= sut.window.contentLayoutRect.maxX + 1)
        }
        #expect(tabs.count == count + 1)
    }

    // MARK: - History exhaustion versus loading, errors and hasMore

    @Test func givenExhaustedHistory_whenRendered_thenTheHistorySurfaceIsOmittedEntirely() async throws {
        // given — settled history on both sources: nothing to load, retry or explain.
        let exhausted = try await present(SidebarViewModelMock())
        let exhaustedOutline = try #require(outlineView(exhausted.host))
        defer { release(exhausted.window) }
        let base = exhaustedOutline.numberOfRows

        // when — the same sidebar with a further page behind both sources.
        var more = HistoryLoadingState()
        more.hasMore = true
        let hasMore = try await present(SidebarViewModelMock(taskHistoryState: more, workflowHistoryState: more))
        let hasMoreOutline = try #require(outlineView(hasMore.host))
        defer { release(hasMore.window) }

        // then — the section header plus the two Load older controls are the only addition; an
        // exhausted history adds no rows, no header and no empty min-height placeholders.
        #expect(hasMoreOutline.numberOfRows - base == 3)
        #expect(elements(labelled: "Load older tasks", in: exhausted.host).isEmpty)
        #expect(!elements(labelled: "Load older workflows", in: hasMore.host).isEmpty)
    }

    @Test func givenOneSourceWithMoreHistory_whenRendered_thenOnlyThatSourceShowsAControl() async throws {
        // given — task history has a further page; workflow history is settled.
        var more = HistoryLoadingState()
        more.hasMore = true
        let exhausted = try await present(SidebarViewModelMock())
        let exhaustedOutline = try #require(outlineView(exhausted.host))
        defer { release(exhausted.window) }
        let oneSource = try await present(SidebarViewModelMock(taskHistoryState: more))
        let oneSourceOutline = try #require(outlineView(oneSource.host))
        defer { release(oneSource.window) }

        // when / then — the settled source renders no empty placeholder row of its own.
        #expect(oneSourceOutline.numberOfRows - exhaustedOutline.numberOfRows == 2)
        #expect(!elements(labelled: "Load older tasks", in: oneSource.host).isEmpty)
        #expect(elements(labelled: "Load older workflows", in: oneSource.host).isEmpty)
    }

    @Test func givenHistoryLoading_whenRendered_thenNoManualControlCanCompeteWithTheGuard() async throws {
        // given — an automatic page already in flight.
        var loading = HistoryLoadingState()
        loading.isLoading = true
        loading.hasMore = true
        let sut = try await present(SidebarViewModelMock(taskHistoryState: loading))
        defer { release(sut.window) }

        // when / then — the loading indicator is the surface; the manual control is absent, so a
        // duplicate request cannot be issued from the view while the existing guard holds the load.
        #expect(!elements(labelled: "Loading tasks…", in: sut.host).isEmpty)
        #expect(elements(labelled: "Load older tasks", in: sut.host).isEmpty)
    }

    @Test func givenAHistoryError_whenRendered_thenTheExplanationAndRetryStay() async throws {
        // given
        let toolError = ToolError.timedOut(tool: "harflow-ctl", seconds: 30)
        var failed = HistoryLoadingState()
        failed.error = toolError
        let sut = try await present(SidebarViewModelMock(taskHistoryState: failed))
        defer { release(sut.window) }

        // when / then — the error copy and the existing retry action remain explicit.
        #expect(!elements(labelled: "Retry tasks", in: sut.host).isEmpty)
        #expect(!elements(labelled: toolError.message, in: sut.host).isEmpty)
    }

    @Test func givenHasMoreHistory_whenLoadOlderIsTapped_thenTheExistingActionFires() async throws {
        // given
        var more = HistoryLoadingState()
        more.hasMore = true
        let vm = SidebarViewModelMock(taskHistoryState: more)
        let sut = try await present(vm)
        defer { release(sut.window) }
        let control = try #require(elements(labelled: "Load older tasks", in: sut.host).first)

        // when
        #expect(press(control))
        await waitUntil { vm.loadOlderTasksTapCount == 1 }

        // then — the manual control drives the same didTapLoadMore action automatic paging uses.
        #expect(vm.loadOlderTasksTapCount == 1)
    }

    // MARK: - Row geometry

    @Test func givenExpandedTree_whenRendered_thenChildRowsMatchTheirParent() async throws {
        // given — a running parent with one expanded child, both two-line rows.
        let vm = SidebarViewModelMock(sections: [SidebarSection(bucket: .running, items: [
            .task(TaskRowModel(
                id: "abc123", backend: "claude", title: "Fix the login bug", status: .running, repoName: "repo",
                ageText: "", indent: 0, subTaskSummary: "1 sub-task", startedAt: .now.addingTimeInterval(-42),
                hasChildren: true, isExpanded: true, guides: []
            )),
            .task(TaskRowModel(
                id: "abc123-child", backend: "codex", title: "Write the migration", status: .running, repoName: "repo",
                ageText: "", indent: 1, startedAt: .now.addingTimeInterval(-10),
                hasChildren: false, isExpanded: true, guides: [.last]
            ))
        ])])
        let sut = try await present(vm, outlineRole: .running)
        let outline = try #require(outlineView(sut.host, role: .running))
        defer { release(sut.window) }
        // Observe completed native reconciliation rather than an in-flight row-height animation.
        var previousFrames: [CGRect] = []
        var stablePasses = 0
        await waitUntil(timeout: 5) {
            sut.host.layoutSubtreeIfNeeded()
            let frames = contentRows(outline).map { outline.rect(ofRow: $0) }
            stablePasses = frames == previousFrames ? stablePasses + 1 : 0
            previousFrames = frames
            return settledNativeRows(outline) && stablePasses >= 6
        }
        try #require(settledNativeRows(outline) && stablePasses >= 6)
        let rows = contentRows(outline)

        // when / then — the sidebar's 7 pt row padding applies symmetrically: the single-line
        // child measures the same height as its single-line parent.
        try #require(rows.count == 2)
        #expect(abs(rowHeight(outline, rows[0]) - rowHeight(outline, rows[1])) <= 1)
    }

    @Test func givenASelectedAliasRow_whenRendered_thenTheSelectedRowFillFitsItsContent() async throws {
        // given — a workflow run and its duplicate alias, both semantically selected.
        let row = TaskRowModel(id: "run-1", backend: "workflow", title: "Plan Review Panel", status: .completed, repoName: "Code", ageText: "1d")
        let vm = SidebarViewModelMock(
            sections: [SidebarSection(bucket: .today, items: [
                .workflow(row),
                .workflowShortcut(row, parentRunID: "run-1")
            ])],
            selection: .workflowRun("run-1")
        )
        let sut = try await present(vm)
        let outline = try #require(outlineView(sut.host))
        defer { release(sut.window) }
        let rows = contentRows(outline)

        // when — the reference content height, measured the way the clipping tests do.
        let reference = NSHostingView(
            rootView: TaskRow(model: row, sidebarAppearance: SidebarRowAppearance(isSelectedFill: true)).fixedSize()
        )
        reference.layoutSubtreeIfNeeded()
        await waitUntil(timeout: 5) {
            sut.host.layoutSubtreeIfNeeded()
            guard let currentOutline = outlineView(sut.host), settledNativeRows(currentOutline) else { return false }
            return contentRows(currentOutline).allSatisfy {
                rowHeight(currentOutline, $0) >= reference.fittingSize.height - 1
            }
        }

        // then — both the natively selected row and the alias `selectedRow` fill fit the row's
        // content; the fill never clips the title, meta or trailing age (§1.5).
        try #require(rows.count == 2)
        #expect(rowHeight(outline, rows[0]) >= reference.fittingSize.height - 1)
        #expect(rowHeight(outline, rows[1]) >= reference.fittingSize.height - 1)
    }
}
