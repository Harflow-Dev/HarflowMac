//
//  TaskTopBarHostedTests.swift
//  MainWindowFeatureTests
//

import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - TaskTopBarHostedTests

/// The shell's principal item in a real window: re-evaluation counts across width bands, the width matrix, and the
/// context title fallback. Needs the AppKit host.
@MainActor @Suite(.serialized) struct TaskTopBarHostedTests {

    private final class Counts {
        var shell = 0
        var principal = 0
    }

    private struct Mounted {
        let window: NSWindow
        let coordinator: MainWindowNavigationCoordinatorMock
        let counts: Counts
    }

    private func mount(width: CGFloat, collapsed: Bool = false) async -> Mounted {
        _ = NSApplication.shared
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        let coordinator = MainWindowNavigationCoordinatorMock()
        let counts = Counts()
        let root = MainWindowNavigationView(coordinator, sidebarCollapsed: collapsed,
                                            onShellEvaluation: { counts.shell += 1 },
                                            onPrincipalEvaluation: { counts.principal += 1 })
            .environment(\.hfReduceMotionOverride, true)
        let controller = NSHostingController(rootView: root)
        controller.sceneBridgingOptions = .all
        let window = M04ToolbarEvidence.makeWindow(controller, size: NSSize(width: width, height: 800))
        await waitUntil(timeout: 5) { window.layoutIfNeeded(); return M04ToolbarEvidence.isPopulated(window) && counts.principal > 0 }
        return Mounted(window: window, coordinator: coordinator, counts: counts)
    }

    private func pump(_ window: NSWindow, times: Int = 15) {
        for _ in 0 ..< times {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
    }

    /// The toolbar items AppKit draws in the bar (not the overflow menu) whose view is in `window`, has no hidden ancestor and
    /// a positive frame inside the window. The principal is among them: it is the centered item, or the one that renders the
    /// exact title being looked for.
    private func visibleItems(in window: NSWindow) -> [NSToolbarItem] {
        guard let toolbar = window.toolbar, let visible = toolbar.visibleItems else { return [] }
        return visible.filter { item in
            guard let view = item.view, view.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
            let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
            return frame.width > 0 && frame.height > 0 && window.frame.insetBy(dx: -1, dy: -1).contains(frame)
        }
    }

    /// `root` and everything reachable through accessibility children and subviews, each object once.
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

    private func strings(of element: NSObject) -> [String] {
        ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"].compactMap { name in
            let selector = NSSelectorFromString(name)
            return element.responds(to: selector) ? element.perform(selector)?.takeUnretainedValue() as? String : nil
        }
    }

    /// Whether a visible toolbar item (the centered principal, or the item that draws it) renders `text` exactly as a whole
    /// accessibility label, value or title. Nothing is substituted: not a predicted title, not the model's, not a substring.
    private func principalRenders(_ text: String, in window: NSWindow) -> Bool {
        let centered = window.toolbar?.centeredItemIdentifiers ?? []
        let items = visibleItems(in: window)
        let ordered = items.filter { centered.contains($0.itemIdentifier) } + items.filter { !centered.contains($0.itemIdentifier) }
        return ordered.contains { item in
            guard let view = item.view else { return false }
            return elements(in: view).contains { strings(of: $0).contains(text) }
        }
    }

    /// What the visible toolbar items draw, for a failure message.
    private func principalDiagnostics(in window: NSWindow) -> String {
        let items = visibleItems(in: window)
        let drawn = items.map { item in
            "\(item.itemIdentifier.rawValue): \(item.view.map { Set(elements(in: $0).flatMap(strings(of:))).sorted() } ?? [])"
        }
        return "toolbar items \(window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []), visible \(drawn)"
    }

    /// Publishes a standalone task's content for `conversation` through the holder the shell reads.
    private func publish(_ mounted: Mounted, title: String, notices: Int = 0) -> TaskTopBarHolder.Tag {
        let holder = mounted.coordinator.topBar
        let tag = TopBarFixtures.tag(TopBarFixtures.Writer(), "conv")
        holder.setShownConversation("conv")
        holder.activate(tag)
        holder.publish(TopBarFixtures.content(title: title, notices: notices), tag: tag)
        return tag
    }

    // MARK: - Re-evaluation

    @Test func givenTheShell_whenTheWindowCrossesBands_thenThePrincipalReevaluatesAndTheShellDoesNot() async {
        // given
        let mounted = await mount(width: 1200)
        defer { mounted.window.close() }
        pump(mounted.window)
        let shell = mounted.counts.shell
        var principal = mounted.counts.principal

        // when each crossing: 1100 edge, 1280 edge, 1600 edge
        for width in [1000.0, 1300.0, 1700.0] {
            mounted.window.setContentSize(NSSize(width: width, height: 800))
            await waitUntil { pump(mounted.window); return mounted.counts.principal > principal }

            // then
            #expect(mounted.counts.principal > principal)
            principal = mounted.counts.principal
        }

        // then the shell body never ran for a crossing
        #expect(mounted.counts.shell == shell)
    }

    @Test func givenTheShell_whenTheWindowResizesWithinABand_thenNeitherReevaluates() async {
        // given
        let mounted = await mount(width: 1300)
        defer { mounted.window.close() }
        pump(mounted.window)
        let shell = mounted.counts.shell
        let principal = mounted.counts.principal

        // when
        for width in [1400.0, 1280.0, 1599.0, 1350.0] {
            mounted.window.setContentSize(NSSize(width: width, height: 800))
            pump(mounted.window)
        }

        // then
        #expect(mounted.counts.shell == shell)
        #expect(mounted.counts.principal == principal)
    }

    @Test func givenAPublishedStatusChange_whenTheHolderChanges_thenOnlyThePrincipalReevaluates() async {
        // given
        let mounted = await mount(width: 1300)
        defer { mounted.window.close() }
        let tag = publish(mounted, title: "Task")
        pump(mounted.window)
        let shell = mounted.counts.shell
        let principal = mounted.counts.principal

        // when
        mounted.coordinator.topBar.publish(TopBarFixtures.content(title: "Task", badge: "Done"), tag: tag)
        await waitUntil { pump(mounted.window); return mounted.counts.principal > principal }

        // then
        #expect(mounted.counts.principal > principal)
        #expect(mounted.counts.shell == shell)
    }

    // MARK: - Fallback and width matrix

    @Test func givenNoTaskContent_whenTheShellDraws_thenThePrincipalShowsTheContextTitle() async {
        // given
        let mounted = await mount(width: 1300)
        defer { mounted.window.close() }
        pump(mounted.window)

        // when
        let title = M04ToolbarEvidence.contextTitle(mounted.coordinator)

        // then
        #expect(principalRenders(title, in: mounted.window), "\(principalDiagnostics(in: mounted.window))")
    }

    @Test(arguments: [1000.0, 1100.0, 1279.0, 1280.0, 1600.0], [false, true])
    func givenALongTitleAndChips_whenTheWindowIsAnyMatrixWidth_thenThePrincipalStaysVisibleWithItsTitle(width: Double, collapsed: Bool) async {
        // given a 120 character title
        let mounted = await mount(width: width, collapsed: collapsed)
        defer { mounted.window.close() }
        let title = String(repeating: "Long title ", count: 11)
        _ = publish(mounted, title: title, notices: 3)

        // when
        await waitUntil { pump(mounted.window); return principalRenders(title, in: mounted.window) }

        // then the principal drew the title, and the toolbar kept its items
        #expect(principalRenders(title, in: mounted.window), "\(principalDiagnostics(in: mounted.window))")
        #expect(mounted.window.toolbar?.visibleItems?.isEmpty == false)
    }

    @Test func givenTheContentIsCleared_whenTheHolderEmpties_thenTheContextTitleReturns() async {
        // given
        let mounted = await mount(width: 1300)
        defer { mounted.window.close() }
        let tag = publish(mounted, title: "Shown task title")
        await waitUntil { pump(mounted.window); return principalRenders("Shown task title", in: mounted.window) }

        // when
        mounted.coordinator.topBar.clear(tag: tag)
        let title = M04ToolbarEvidence.contextTitle(mounted.coordinator)
        await waitUntil { pump(mounted.window); return principalRenders(title, in: mounted.window) }

        // then
        #expect(principalRenders(title, in: mounted.window), "\(principalDiagnostics(in: mounted.window))")
    }
}
