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
    private func principal(detailWidth: CGFloat, title: String = "Review preload bridge") async -> Principal {
        _ = NSApplication.shared
        let holder = TaskTopBarHolder()
        let layout = TopBarLayoutState()
        layout.setDetailWidth(detailWidth)
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
        let titleElement = try #require(sut.fixture.element(title))
        let titleFrame = try #require(sut.fixture.frame(titleElement))
        let cap = GroupTopBarBudget.cap(detailWidth: 1016)
        #expect(titleFrame.width < cap, "title \(titleFrame.width) within cap \(cap)")
        let badgeElement = try #require(sut.fixture.element("1 running · 2 done"))
        let badge = try #require(sut.fixture.frame(badgeElement))
        #expect(badge.maxX <= cap + 1, "the whole badge stays inside the budget")
    }

    @Test func givenTheBudget_whenCancelAllIsShownOrHidden_thenTheCapIsTheSame() {
        // The width of Cancel all is reserved in the budget whether or not the button shows, so the meta cannot toggle.
        #expect(GroupTopBarBudget.cap(detailWidth: 1016) == 1016 - GroupTopBarBudget.reservedButtons - GroupTopBarBudget.margins)
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

    // MARK: Group screen actions

    /// The production shell around the group screen, so its toolbar items exist in a real `NSToolbar`.
    private func screen(empty: Bool, canCancelAll: Bool) async -> NSWindow {
        _ = NSApplication.shared
        let vm = ParallelViewModelMock(groupName: "release", statusSummary: empty ? nil : "1 running · 2 done", canCancelAll: canCancelAll, isEmpty: empty,
                                       columns: empty ? [] : ParallelViewModelMock.sampleColumns())
        let coordinator = MainWindowNavigationCoordinatorMock()
        coordinator.parallelBuilder = { _ in ParallelView(vm, initiallyPrepared: true).id("release").eraseToAnyView() }
        coordinator.selection = .group("release")
        let controller = NSHostingController(rootView: AnyView(MainWindowNavigationView(coordinator).environment(\.hfReduceMotionOverride, true)))
        controller.sceneBridgingOptions = .all
        let window = M04ToolbarEvidence.makeWindow(controller, size: NSSize(width: 1280, height: 800))
        await waitUntil(timeout: 10) {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
            return label(window, "View prompt") != nil
        }
        return window
    }

    private func tree(_ window: NSWindow) -> [NSObject] {
        var result: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        var queue: [NSObject] = (window.toolbar?.items.compactMap(\.view) ?? []) + [window.contentView].compactMap(\.self)
        while let next = queue.popLast(), result.count < 8000 {
            guard seen.insert(ObjectIdentifier(next)).inserted else { continue }
            result.append(next)
            let children = NSSelectorFromString("accessibilityChildren")
            if next.responds(to: children), let kids = next.perform(children)?.takeUnretainedValue() as? [NSObject] { queue.append(contentsOf: kids) }
            if let view = next as? NSView { queue.append(contentsOf: view.subviews) }
        }
        return result
    }

    private func label(_ window: NSWindow, _ text: String) -> NSObject? {
        tree(window).first { object in
            ["accessibilityLabel", "accessibilityValue"].contains { key in
                let selector = NSSelectorFromString(key)
                return object.responds(to: selector) && (object.perform(selector)?.takeUnretainedValue() as? String) == text
            }
        }
    }

    @Test func givenAnEmptyGroup_whenMounted_thenViewPromptIsDisabledAndThereIsNoCancelAll() async throws {
        // given / when
        let window = await screen(empty: true, canCancelAll: false)
        defer { window.contentViewController = nil; window.close() }

        // then
        let prompt = try #require(label(window, "View prompt"))
        #expect(TaskStoppingHostedTests.isEnabled(prompt) == false)
        #expect(label(window, "Cancel all") == nil)
        #expect(label(window, "No tasks in this group any more.") != nil)
    }

    @Test func givenARunningGroup_whenMounted_thenBothButtonsAreEnabledAndTheGroupNameIsNotInTheContent() async throws {
        // given / when
        let window = await screen(empty: false, canCancelAll: true)
        defer { window.contentViewController = nil; window.close() }

        // then
        let prompt = try #require(label(window, "View prompt"))
        #expect(TaskStoppingHostedTests.isEnabled(prompt) == true)
        #expect(label(window, "Cancel all") != nil)
        #expect(label(window, "release") == nil, "the group name is in the top bar, not the content")
    }
}
