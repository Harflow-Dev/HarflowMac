//
//  TaskTopBarLoadingHostedTests.swift
//  MainWindowFeatureTests
//

import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - TaskTopBarLoadingHostedTests

/// The standalone task's principal while the task loads, in the production shell and a real window: the known title
/// drawn as the loaded one, the unknown-title block, the hidden placeholder blocks, the not-found caption, and the
/// transitions between the pre-mount state, the mounted writer's states and the loaded content. Needs the AppKit host.
@MainActor @Suite(.serialized) struct TaskTopBarLoadingHostedTests {

    private static let conversation = "conv"
    private static let caption = "Harflow · Work"
    private static let known = "Review preload bridge"

    @MainActor private struct Mounted {
        let window: NSWindow
        let coordinator: MainWindowNavigationCoordinatorMock
        var holder: TaskTopBarHolder { coordinator.topBar }
    }

    private func mount(width: CGFloat = 1280, conversation: String = conversation) async -> Mounted {
        _ = NSApplication.shared
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        let coordinator = MainWindowNavigationCoordinatorMock()
        coordinator.selection = .task(conversation)
        coordinator.topBar.setShownConversation(conversation)
        let root = MainWindowNavigationView(coordinator).environment(\.hfReduceMotionOverride, true)
        let controller = NSHostingController(rootView: root)
        controller.sceneBridgingOptions = .all
        let window = M04ToolbarEvidence.makeWindow(controller, size: NSSize(width: width, height: 800))
        await waitUntil(timeout: 5) { window.layoutIfNeeded(); return M04ToolbarEvidence.isPopulated(window) }
        return Mounted(window: window, coordinator: coordinator)
    }

    private func pump(_ window: NSWindow, times: Int = 15) {
        for _ in 0 ..< times {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
    }

    // MARK: Inspection

    private func elements(in root: NSObject) -> [NSObject] {
        var result: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        var queue: [NSObject] = [root]
        while let next = queue.popLast(), result.count < 6000 {
            guard seen.insert(ObjectIdentifier(next)).inserted else { continue }
            result.append(next)
            let children = NSSelectorFromString("accessibilityChildren")
            if next.responds(to: children), let kids = next.perform(children)?.takeUnretainedValue() as? [NSObject] {
                queue.append(contentsOf: kids)
            }
            if let view = next as? NSView { queue.append(contentsOf: view.subviews) }
        }
        return result
    }

    private func string(_ element: NSObject, _ name: String) -> String? {
        let selector = NSSelectorFromString(name)
        return element.responds(to: selector) ? element.perform(selector)?.takeUnretainedValue() as? String : nil
    }

    private func strings(of element: NSObject) -> [String] {
        ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"].compactMap { string(element, $0) }.filter { !$0.isEmpty }
    }

    /// Every non-empty accessibility string the toolbar's items draw.
    private func toolbarStrings(_ window: NSWindow) -> Set<String> {
        Set((window.toolbar?.items ?? []).compactMap(\.view).flatMap(elements(in:)).flatMap(strings(of:)))
    }

    private func renders(_ text: String, in window: NSWindow) -> Bool { toolbarStrings(window).contains(text) }

    private func rendersPrefix(_ prefix: String, in window: NSWindow) -> Bool { toolbarStrings(window).contains { $0.hasPrefix(prefix) } }

    private func titleElement(_ text: String, in window: NSWindow) -> NSObject? {
        (window.toolbar?.items ?? []).compactMap(\.view).flatMap(elements(in:)).first { strings(of: $0).contains(text) }
    }

    private func settle(_ mounted: Mounted, _ condition: @MainActor () -> Bool) async {
        await waitUntil(timeout: 5) { pump(mounted.window); return condition() }
    }

    private func screenWidth(of item: NSToolbarItem?, in window: NSWindow) -> CGFloat? {
        guard let view = item?.view, view.window === window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil)).width
    }

    private func principalWidth(_ window: NSWindow) -> CGFloat? {
        guard let toolbar = window.toolbar else { return nil }
        let item = toolbar.items.first { toolbar.centeredItemIdentifiers.contains($0.itemIdentifier) && $0.view != nil }
        return screenWidth(of: item, in: window)
    }

    private func newWriter() -> TaskTopBarHolder.Tag { TopBarFixtures.tag(TopBarFixtures.Writer(), Self.conversation) }

    // MARK: - Principal drawing

    @Test func givenAKnownTitleInThePreMountSlot_whenThePrincipalDraws_thenItShowsTheTitleWithItsLabelAndNoCaption() async throws {
        // given
        let mounted = await mount()
        defer { mounted.window.close() }
        pump(mounted.window)
        #expect(renders(Self.caption, in: mounted.window), "the caption shows before any slot state")

        // when
        mounted.holder.setPreMountSlot(.loading(title: Self.known))
        await settle(mounted) { renders(Self.known, in: mounted.window) }

        // then
        #expect(renders(Self.known, in: mounted.window))
        #expect(!renders(Self.caption, in: mounted.window))
        let element = try #require(titleElement(Self.known, in: mounted.window))
        #expect(strings(of: element).contains(Self.known))
        // the help text is the title, as the loaded title's help
        let help = try #require(string(element, "accessibilityHelp"))
        #expect(help == Self.known)
    }

    @Test func givenAKnownTitle_whenThePrincipalDraws_thenTheBadgeBusyAndMetaBlocksAreHiddenFromAccessibility() async {
        // given the strings of the bar with no slot state, minus the caption: what the bar draws besides the principal's text
        let mounted = await mount()
        defer { mounted.window.close() }
        pump(mounted.window)
        let others = toolbarStrings(mounted.window).subtracting([Self.caption])

        // when
        mounted.holder.setPreMountSlot(.loading(title: Self.known))
        await settle(mounted) { renders(Self.known, in: mounted.window) }

        // then the title is the only new string; the placeholder blocks add none
        #expect(toolbarStrings(mounted.window) == others.union([Self.known]))
    }

    @Test func givenAnUnknownTitle_whenThePrincipalDraws_thenItDrawsTheBlockWithNoCaptionAndNoText() async {
        // given
        let mounted = await mount()
        defer { mounted.window.close() }
        pump(mounted.window)
        let others = toolbarStrings(mounted.window).subtracting([Self.caption])

        // when
        mounted.holder.setPreMountSlot(.loading(title: nil))
        await settle(mounted) { !renders(Self.caption, in: mounted.window) }

        // then
        #expect(!renders(Self.caption, in: mounted.window))
        #expect(toolbarStrings(mounted.window) == others)
    }

    @Test func givenAnEmptyKnownTitle_whenThePrincipalDraws_thenItDrawsTheBlockInsteadOfEmptyText() async {
        // given
        let mounted = await mount()
        defer { mounted.window.close() }
        pump(mounted.window)
        let others = toolbarStrings(mounted.window).subtracting([Self.caption])

        // when
        mounted.holder.setPreMountSlot(.loading(title: ""))
        await settle(mounted) { !renders(Self.caption, in: mounted.window) }

        // then
        #expect(!renders(Self.caption, in: mounted.window))
        #expect(toolbarStrings(mounted.window) == others)
    }

    @Test func givenNotFoundPublishedByTheWriter_whenThePrincipalDraws_thenItShowsTheCaption() async {
        // given a pre-mount loading state
        let mounted = await mount()
        defer { mounted.window.close() }
        mounted.holder.setPreMountSlot(.loading(title: Self.known))
        await settle(mounted) { renders(Self.known, in: mounted.window) }

        // when the mounted writer reports not found
        let tag = newWriter()
        mounted.holder.activate(tag)
        mounted.holder.publish(slot: .notFound, tag: tag)
        await settle(mounted) { renders(Self.caption, in: mounted.window) }

        // then the writer's state wins over the pre-mount state
        #expect(renders(Self.caption, in: mounted.window))
        #expect(!renders(Self.known, in: mounted.window))
    }

    @Test func givenAWriterLoadingSlot_whenThePrincipalDraws_thenItIsTheSameShapeAsThePreMountState() async {
        // given
        let mounted = await mount()
        defer { mounted.window.close() }

        // when
        let tag = newWriter()
        mounted.holder.activate(tag)
        mounted.holder.publish(slot: .loading(title: Self.known), tag: tag)
        await settle(mounted) { renders(Self.known, in: mounted.window) }

        // then
        #expect(renders(Self.known, in: mounted.window))
        #expect(!renders(Self.caption, in: mounted.window))
    }

    @Test func givenNoSlotStateAtAll_whenThePrincipalDraws_thenItShowsTheCaption() async {
        // given / when
        let mounted = await mount()
        defer { mounted.window.close() }
        await settle(mounted) { renders(Self.caption, in: mounted.window) }

        // then
        #expect(renders(Self.caption, in: mounted.window))
    }

    @Test func givenTheLoadingBar_whenTheWindowIsNarrowOrWide_thenTheMetaBlockIsOnlyThereWhenWide() async throws {
        // given the unknown-title loading bar in a wide window
        let wide = await mount(width: 1280)
        defer { wide.window.close() }
        wide.holder.setPreMountSlot(.loading(title: nil))
        await settle(wide) { !renders(Self.caption, in: wide.window) }
        pump(wide.window, times: 30)
        let wideWidth = try #require(principalWidth(wide.window))

        // and in a narrow one
        let narrow = await mount(width: 1000)
        defer { narrow.window.close() }
        narrow.holder.setPreMountSlot(.loading(title: nil))
        await settle(narrow) { !renders(Self.caption, in: narrow.window) }
        pump(narrow.window, times: 30)
        let narrowWidth = try #require(principalWidth(narrow.window))

        // then the wide bar is wider by at least the meta floor (the solver may shorten the flexible meta block under the
        // cap, so not the full 170 points), as the loaded meta is absent below 1100
        print("TOPBAR loading principal width wide \(wideWidth), narrow \(narrowWidth)")
        #expect(wideWidth - narrowWidth >= TopBarPrincipalLayout.metaFloor,
                "meta block missing at 1280 or present at 1000: \(wideWidth) vs \(narrowWidth)")
    }

    // MARK: - Transitions

    @Test func givenAKnownPreMountTitle_whenTheViewMountsAndPublishesContent_thenTheLoadedBarReplacesIt() async {
        // given
        let mounted = await mount()
        defer { mounted.window.close() }
        mounted.holder.setPreMountSlot(.loading(title: Self.known))
        await settle(mounted) { renders(Self.known, in: mounted.window) }

        // when the VM activates and publishes the loaded content with the same title
        let tag = newWriter()
        mounted.holder.activate(tag)
        mounted.holder.publish(TopBarFixtures.content(title: Self.known), tag: tag)
        await settle(mounted) { rendersPrefix("Running", in: mounted.window) }

        // then
        #expect(renders(Self.known, in: mounted.window))
        #expect(rendersPrefix("Running", in: mounted.window), "the loaded badge is drawn")
        #expect(!renders(Self.caption, in: mounted.window))
    }

    @Test func givenAnUnknownPreMountTask_whenTheViewMountsAndReportsNotFound_thenTheCaptionReplacesTheBlock() async {
        // given
        let mounted = await mount()
        defer { mounted.window.close() }
        mounted.holder.setPreMountSlot(.loading(title: nil))
        await settle(mounted) { !renders(Self.caption, in: mounted.window) }
        #expect(!renders(Self.caption, in: mounted.window))

        // when
        let tag = newWriter()
        mounted.holder.activate(tag)
        mounted.holder.publish(slot: .notFound, tag: tag)
        await settle(mounted) { renders(Self.caption, in: mounted.window) }

        // then
        #expect(renders(Self.caption, in: mounted.window))
    }

    @Test func givenTaskAShownThenTaskBSelected_whenThePreMountSlotMoves_thenOnlyBsTitleIsDrawn() async {
        // given task A loaded
        let mounted = await mount()
        defer { mounted.window.close() }
        let tagA = newWriter()
        mounted.holder.activate(tagA)
        mounted.holder.publish(TopBarFixtures.content(title: "Task A"), tag: tagA)
        await settle(mounted) { renders("Task A", in: mounted.window) }

        // when the selection moves to B: the coordinator drops the shown conversation and writes B's pre-mount title
        mounted.holder.setShownConversation("other")
        mounted.holder.setPreMountSlot(.loading(title: "Task B"))
        await settle(mounted) { renders("Task B", in: mounted.window) }

        // then
        #expect(renders("Task B", in: mounted.window))
        #expect(!renders("Task A", in: mounted.window))
        #expect(!renders(Self.caption, in: mounted.window))

        // when a late write from A arrives
        mounted.holder.publish(TopBarFixtures.content(title: "Task A late"), tag: tagA)
        pump(mounted.window)

        // then it stays hidden
        #expect(!renders("Task A late", in: mounted.window))
        #expect(renders("Task B", in: mounted.window))
    }

    @Test func givenAWriterReplacedBySameSubjectWriter_whenTheNewOneActivates_thenItsStateIsDrawnAndTheOldOnesLateWriteIsNot() async {
        // given
        let mounted = await mount()
        defer { mounted.window.close() }
        let first = newWriter()
        mounted.holder.activate(first)
        mounted.holder.publish(slot: .loading(title: "First view"), tag: first)
        await settle(mounted) { renders("First view", in: mounted.window) }

        // when a rebuilt view's writer takes over
        let second = newWriter()
        mounted.holder.publish(slot: .loading(title: "Second view"), tag: second)
        mounted.holder.activate(second)
        await settle(mounted) { renders("Second view", in: mounted.window) }
        mounted.holder.publish(slot: .loading(title: "First view again"), tag: first)
        pump(mounted.window)

        // then
        #expect(renders("Second view", in: mounted.window))
        #expect(!renders("First view", in: mounted.window))
        #expect(!renders("First view again", in: mounted.window))
    }

    @Test func givenAStaleLoadingPublication_whenTheWriterClears_thenThePreMountSlotThenTheCaptionTakeOver() async {
        // given
        let mounted = await mount()
        defer { mounted.window.close() }
        mounted.holder.setPreMountSlot(.loading(title: "From listing"))
        let tag = newWriter()
        mounted.holder.activate(tag)
        mounted.holder.publish(slot: .loading(title: "From writer"), tag: tag)
        await settle(mounted) { renders("From writer", in: mounted.window) }

        // when the writer clears
        mounted.holder.clear(tag: tag)
        await settle(mounted) { renders("From listing", in: mounted.window) }

        // then the pre-mount slot is drawn
        #expect(renders("From listing", in: mounted.window))
        #expect(!renders("From writer", in: mounted.window))

        // when the pre-mount slot is gone too
        mounted.holder.setPreMountSlot(nil)
        await settle(mounted) { renders(Self.caption, in: mounted.window) }

        // then the caption returns
        #expect(renders(Self.caption, in: mounted.window))
    }

    @Test func givenALoadingWriter_whenItDisappearsAndReappears_thenTheStateLeavesAndReturns() async {
        // given
        let mounted = await mount()
        defer { mounted.window.close() }
        let tag = newWriter()
        mounted.holder.activate(tag)
        mounted.holder.publish(slot: .loading(title: "Known"), tag: tag)
        await settle(mounted) { renders("Known", in: mounted.window) }

        // when the view goes away
        mounted.holder.deactivate(tag)
        await settle(mounted) { renders(Self.caption, in: mounted.window) }

        // then
        #expect(renders(Self.caption, in: mounted.window))
        #expect(!renders("Known", in: mounted.window))

        // when it appears again and asks to be shown, with its stored state
        mounted.holder.activate(tag)
        await settle(mounted) { renders("Known", in: mounted.window) }

        // then
        #expect(renders("Known", in: mounted.window))
        #expect(!renders(Self.caption, in: mounted.window))
    }
}
