//
//  ParallelGroupTopBarHostedTests.swift
//  MainWindowFeatureTests
//

import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - ParallelGroupTopBarHostedTests

/// A Parallel group's top bar: the principal (`TaskTopBarPrincipal`) drawn for the detail widths the approved window
/// sizes give it, and the group screen's own toolbar actions. Needs the AppKit host.
@MainActor @Suite(.serialized) struct ParallelGroupTopBarHostedTests {
    private static let sentence = "Enforced for every agent here: Network: not controlled."
    private static let metaIdentifier = "group-top-bar.meta"

    @MainActor final class Counter { var value = 0 }

    @MainActor private struct Principal {
        let fixture: RedesignHost
        let holder: TaskTopBarHolder
        let layout: TopBarLayoutState
        let tag: TaskTopBarHolder.Tag
        let evaluations: Counter
        func close() { fixture.close() }
    }

    private func counts(_ statuses: [String]) -> ParallelStatusCounts {
        ParallelStatusCounts(tasks: statuses.enumerated().map { TaskInfo(.object(["task_id": .string("t\($0.offset)"), "status": .string($0.element)]))! })
    }

    /// The principal for `detailWidth`: the width a window of the approved size gives the detail column.
    private func principal(detailWidth: CGFloat, windowWidth: CGFloat? = nil, title: String = "Review preload bridge") async -> Principal {
        _ = NSApplication.shared
        let holder = TaskTopBarHolder()
        let layout = TopBarLayoutState()
        layout.setDetailWidth(detailWidth)
        if let windowWidth { layout.setWindowWidth(windowWidth) }
        let writer = TopBarFixtures.Writer()
        let tag = TaskTopBarHolder.Tag(writer: ObjectIdentifier(writer), subject: .group(title))
        holder.setShownSubject(.group(title))
        holder.publish(GroupTopBarContent(title: title, badge: TaskBadgeModel.group(counts(["running", "completed", "completed"])),
                                          meta: Self.sentence), tag: tag)
        holder.activate(tag)
        let evaluations = Counter()
        let view = TaskTopBarPrincipal(holder: holder, layout: layout, fallbackTitle: "Harflow · Work", status: AnyView(Color.clear.frame(width: 7, height: 7)),
                                       onEvaluation: { evaluations.value += 1 })
        let fixture = RedesignHost(view, size: CGSize(width: 1400, height: 40))
        await fixture.settle { fixture.element(Self.metaIdentifier) != nil }
        var passes = 0
        await fixture.settle { passes += 1; return passes > 8 }
        return Principal(fixture: fixture, holder: holder, layout: layout, tag: tag, evaluations: evaluations)
    }

    /// The principal's drawn width: what its layout asks for. It includes the meta only while the meta is whole.
    private func drawnWidth(_ sut: Principal) -> CGFloat { sut.fixture.host.fittingSize.width }

    /// The meta element's own frame width: its whole ideal width, or zero (or no element) when the layout dropped it.
    private func metaFrameWidth(_ sut: Principal) -> CGFloat {
        sut.fixture.element(Self.metaIdentifier).flatMap { sut.fixture.frame($0) }?.width ?? 0
    }

    /// The sentence's ideal single-line width at the principal's meta font.
    private func idealMetaWidth() -> CGFloat {
        NSHostingView(rootView: Text(Self.sentence).font(.hf(.secondary)).lineLimit(1).fixedSize()).fittingSize.width
    }

    // MARK: Whole meta at the approved sizes

    @Test(arguments: [CGFloat(1016), 1216, 1336, 1536])
    func givenTheDrawnSentence_whenTheDetailColumnIsWide_thenTitleBadgeAndMetaAreWhole(detailWidth: CGFloat) async {
        // given / when
        let sut = await principal(detailWidth: detailWidth)
        defer { sut.close() }

        // then
        let dropped = await principal(detailWidth: 736)
        defer { dropped.close() }
        #expect(drawnWidth(sut) - drawnWidth(dropped) >= 300, "meta dropped at detail width \(detailWidth): \(drawnWidth(sut)) vs \(drawnWidth(dropped))")
        #expect(drawnWidth(sut) <= GroupTopBarBudget.cap(detailWidth: detailWidth) + 1)
        #expect(abs(metaFrameWidth(sut) - idealMetaWidth()) <= 2, "the meta element is drawn at its ideal width: \(metaFrameWidth(sut))")
        #expect(sut.fixture.element("Review preload bridge") != nil)
        #expect(sut.fixture.element("1 running · 2 done") != nil)
    }

    @Test func givenTheMinimumWindowsDetailColumn_whenDrawn_thenTheMetaIsDroppedAndTitleAndBadgeStayWhole() async {
        // given / when
        let sut = await principal(detailWidth: 736)
        defer { sut.close() }

        // then
        let wide = await principal(detailWidth: 1016)
        defer { wide.close() }
        #expect(drawnWidth(wide) - drawnWidth(sut) >= 300, "the meta is dropped, not shortened: \(drawnWidth(sut)) vs \(drawnWidth(wide))")
        #expect(drawnWidth(sut) <= GroupTopBarBudget.cap(detailWidth: 736) + 1)
        #expect(metaFrameWidth(sut) <= 1, "the dropped meta element has no drawn width: \(metaFrameWidth(sut))")
        #expect(sut.fixture.element("Review preload bridge") != nil)
        #expect(sut.fixture.element("1 running · 2 done") != nil)
    }

    @Test func givenAVeryLongGroupName_whenDrawn_thenTheTitleTruncatesAndTheBadgeAndMetaStayWhole() async throws {
        // given
        let title = String(repeating: "A very long group name ", count: 8)

        // when
        let sut = await principal(detailWidth: 1016, title: title)
        defer { sut.close() }

        // then
        #expect(drawnWidth(sut) <= GroupTopBarBudget.cap(detailWidth: 1016) + 1, "everything sits inside the budget: \(drawnWidth(sut))")
        #expect(drawnWidth(sut) >= GroupTopBarBudget.cap(detailWidth: 1016) - 1, "the title gives way to the whole meta, so the bar fills its budget")
        #expect(abs(metaFrameWidth(sut) - idealMetaWidth()) <= 2, "the meta element is whole: \(metaFrameWidth(sut))")
        let titleElement = try #require(sut.fixture.element(title))
        let titleFrame = try #require(sut.fixture.frame(titleElement))
        let cap = GroupTopBarBudget.cap(detailWidth: 1016)
        #expect(titleFrame.width < cap, "title \(titleFrame.width) within cap \(cap)")
        let badgeElement = try #require(sut.fixture.element("1 running · 2 done"))
        let badge = try #require(sut.fixture.frame(badgeElement))
        #expect(badge.maxX <= cap + 1, "the whole badge stays inside the budget")
    }

    @Test func givenTheCentredPrincipal_whenTheWindowIsNarrow_thenTheCapIsBoundedByTheRoomBesideTheCentre() {
        // The principal is centred in the window, so it also cannot be wider than twice the room between the centre and
        // the trailing buttons, whatever the detail column offers.
        let centred = 2 * (CGFloat(1000) / 2 - GroupTopBarBudget.reservedButtons - GroupTopBarBudget.margins)
        #expect(GroupTopBarBudget.cap(detailWidth: 5000, windowWidth: 1000) == centred)
        #expect(GroupTopBarBudget.cap(detailWidth: 400, windowWidth: 1000) == 400 - GroupTopBarBudget.reservedButtons - GroupTopBarBudget.margins)
        #expect(GroupTopBarBudget.cap(detailWidth: 1016, windowWidth: nil) == 1016 - GroupTopBarBudget.reservedButtons - GroupTopBarBudget.margins)
    }

    // MARK: Unchanged snapshot

    @Test func givenAnUnchangedGroupSnapshot_whenPublishedAgain_thenThePrincipalDoesNotReEvaluate() async throws {
        // given
        let sut = await principal(detailWidth: 1016)
        defer { sut.close() }
        let before = sut.evaluations.value
        let content = try #require(sut.holder.shownGroup)

        // when
        for _ in 0 ..< 5 { sut.holder.publish(content, tag: sut.tag) }
        var passes = 0
        await sut.fixture.settle { passes += 1; return passes > 10 }

        // then
        #expect(sut.evaluations.value == before)
    }

    // MARK: Group screen in the production shell

    @MainActor @Observable final class GroupScreenVM: ParallelViewModel {
        var groupName = "release"
        var statusSummary: String?
        var showPrompt = false
        var canCancelAll = true
        var isEmpty = false
        var columns: [ParallelColumnModel] = ParallelViewModelMock.sampleColumns()
        var horizontalPosition: ParallelViewportPosition? = ParallelViewportPosition()
        func didAppear() {}
        func didDisappear() {}
        func didTapViewPrompt() { showPrompt.toggle() }
        func didTapCancelAll() {}
    }

    @MainActor private struct Shell {
        let window: NSWindow
        let viewModel: GroupScreenVM
        let coordinator: MainWindowNavigationCoordinatorMock
        func close() { window.contentViewController = nil; window.close() }
    }

    /// The production shell around the group screen, with the group's top bar content published and active, so the
    /// principal and the screen's toolbar buttons are items of one real `NSToolbar`.
    private func shell(width: CGFloat = 1280, height: CGFloat = 800, collapsed: Bool = false, title: String = "release",
                       empty: Bool = false, canCancelAll: Bool = true) async -> Shell {
        _ = NSApplication.shared
        let vm = GroupScreenVM()
        vm.isEmpty = empty
        vm.canCancelAll = canCancelAll
        if empty { vm.columns = [] }
        let coordinator = MainWindowNavigationCoordinatorMock()
        coordinator.parallelBuilder = { _ in ParallelView(vm, initiallyPrepared: true).id("group").eraseToAnyView() }
        coordinator.selection = .group(title)
        let writer = TopBarFixtures.Writer()
        let tag = TaskTopBarHolder.Tag(writer: ObjectIdentifier(writer), subject: .group(title))
        coordinator.topBar.setShownSubject(.group(title))
        let counts = counts(empty ? [] : ["running", "completed", "completed"])
        coordinator.topBar.publish(GroupTopBarContent(title: title, badge: TaskBadgeModel.group(counts), meta: empty ? nil : Self.sentence), tag: tag)
        coordinator.topBar.activate(tag)
        retainedWriters.append(writer)
        let controller = NSHostingController(rootView: AnyView(MainWindowNavigationView(coordinator, sidebarCollapsed: collapsed)
            .environment(\.hfReduceMotionOverride, true)))
        controller.sceneBridgingOptions = .all
        let window = M04ToolbarEvidence.makeWindow(controller, size: NSSize(width: width, height: height))
        await waitUntil(timeout: 10) {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
            return label(window, "View prompt") != nil && item(window, containing: title) != nil
        }
        var passes = 0
        await waitUntil(timeout: 3) {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
            passes += 1
            return passes >= 25
        }
        return Shell(window: window, viewModel: vm, coordinator: coordinator)
    }

    private var retainedWriters: [TopBarFixtures.Writer] {
        get { Self.writers }
        nonmutating set { Self.writers = newValue }
    }

    private static var writers: [TopBarFixtures.Writer] = []

    private func subtree(_ root: NSObject) -> [NSObject] {
        var result: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        var queue: [NSObject] = [root]
        while let next = queue.popLast(), result.count < 4000 {
            guard seen.insert(ObjectIdentifier(next)).inserted else { continue }
            result.append(next)
            let children = NSSelectorFromString("accessibilityChildren")
            if next.responds(to: children), let kids = next.perform(children)?.takeUnretainedValue() as? [NSObject] { queue.append(contentsOf: kids) }
            if let view = next as? NSView { queue.append(contentsOf: view.subviews) }
        }
        return result
    }

    private func tree(_ window: NSWindow) -> [NSObject] {
        (window.toolbar?.items.compactMap(\.view) ?? []).flatMap(subtree) + [window.contentView].compactMap(\.self).flatMap(subtree)
    }

    private func matches(_ object: NSObject, _ text: String) -> Bool {
        ["accessibilityLabel", "accessibilityValue"].contains { key in
            let selector = NSSelectorFromString(key)
            return object.responds(to: selector) && (object.perform(selector)?.takeUnretainedValue() as? String) == text
        }
    }

    private func label(_ window: NSWindow, _ text: String) -> NSObject? { tree(window).first { matches($0, text) } }

    private func item(_ window: NSWindow, containing text: String) -> NSToolbarItem? {
        window.toolbar?.items.first { item in item.view.map { subtree($0).contains { matches($0, text) } } ?? false }
    }

    private func screenFrame(_ item: NSToolbarItem?, in window: NSWindow) -> CGRect? {
        guard let view = item?.view, view.window === window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    private func isInBar(_ item: NSToolbarItem?, in window: NSWindow) -> Bool {
        guard let item, let visible = window.toolbar?.visibleItems else { return false }
        return visible.contains { $0 === item }
    }

    // MARK: The centred principal against the toolbar buttons

    @Test(arguments: [(CGFloat(1280), CGFloat(800), false), (1280, 800, true), (1000, 620, false), (1000, 620, true)],
          ["release", String(repeating: "A very long group name ", count: 8)])
    func givenAGroupName_whenMountedInTheShell_thenThePrincipalNeverOverlapsViewPromptAndNothingOverflows(
        size: (CGFloat, CGFloat, Bool), title: String
    ) async throws {
        // given / when
        let mounted = await shell(width: size.0, height: size.1, collapsed: size.2, title: title)
        defer { mounted.close() }
        let window = mounted.window

        // then
        let principal = try #require(item(window, containing: title), "no principal item at \(size)")
        let prompt = try #require(item(window, containing: "View prompt"))
        let cancelAll = try #require(item(window, containing: "Cancel all"))
        let principalFrame = try #require(screenFrame(principal, in: window))
        let promptFrame = try #require(screenFrame(prompt, in: window))
        #expect(principalFrame.maxX <= promptFrame.minX + 0.5, "principal \(principalFrame) overlaps View prompt \(promptFrame) at \(size)")
        #expect(isInBar(principal, in: window) && isInBar(prompt, in: window) && isInBar(cancelAll, in: window), "an item overflowed at \(size)")
        #expect(window.toolbar?.visibleItems?.count == window.toolbar?.items.count, "the toolbar has overflow at \(size)")
    }

    @Test func givenCancelAllDisappears_whenTheLastTaskSettles_thenThePrincipalAndItsMetaDoNotChange() async throws {
        // given
        let mounted = await shell()
        defer { mounted.close() }
        let window = mounted.window
        let before = try #require(screenFrame(item(window, containing: "release"), in: window))
        let metaBefore = try #require(label(window, Self.sentence))

        // when — Cancel all leaves the toolbar
        mounted.viewModel.canCancelAll = false
        var passes = 0
        await waitUntil(timeout: 3) {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
            passes += 1
            return passes >= 25
        }

        // then — View prompt stays, Cancel all is gone, and the principal's width and meta are unchanged
        #expect(item(window, containing: "Cancel all") == nil)
        let after = try #require(screenFrame(item(window, containing: "release"), in: window))
        #expect(abs(after.width - before.width) <= 0.5, "the principal changed width: \(before.width) to \(after.width)")
        let metaAfter = try #require(label(window, Self.sentence))
        let beforeWidth = (metaBefore as? any NSAccessibilityProtocol)?.accessibilityFrame().width
        let afterWidth = (metaAfter as? any NSAccessibilityProtocol)?.accessibilityFrame().width
        #expect(beforeWidth == afterWidth)
    }

    // MARK: Group screen actions

    @Test func givenAnEmptyGroup_whenMounted_thenViewPromptIsDisabledAndThereIsNoCancelAll() async throws {
        // given / when
        let mounted = await shell(empty: true, canCancelAll: false)
        defer { mounted.close() }

        // then
        let prompt = try #require(label(mounted.window, "View prompt"))
        #expect(TaskStoppingHostedTests.isEnabled(prompt) == false)
        #expect(label(mounted.window, "Cancel all") == nil)
        #expect(label(mounted.window, "No tasks in this group any more.") != nil)
    }

    @Test func givenARunningGroup_whenMounted_thenBothButtonsAreEnabledAndTheGroupNameIsNotInTheContent() async throws {
        // given / when
        let mounted = await shell()
        defer { mounted.close() }

        // then
        let prompt = try #require(label(mounted.window, "View prompt"))
        #expect(TaskStoppingHostedTests.isEnabled(prompt) == true)
        #expect(label(mounted.window, "Cancel all") != nil)
        let contentOnly = mounted.window.contentView.map(subtree) ?? []
        #expect(!contentOnly.contains { matches($0, "release") }, "the group name is in the top bar, not the content")
    }
}
