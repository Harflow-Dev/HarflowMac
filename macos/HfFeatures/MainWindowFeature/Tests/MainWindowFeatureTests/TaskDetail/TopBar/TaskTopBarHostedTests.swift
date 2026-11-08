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

    private func texts(in window: NSWindow) -> [String] {
        var result: [String] = []
        var queue: [NSObject] = [window]
        var visited = 0
        while let next = queue.popLast(), visited < 5000 {
            visited += 1
            if let accessible = next as? any NSAccessibilityProtocol {
                if let label = accessible.accessibilityLabel(), !label.isEmpty { result.append(label) }
                if let value = accessible.accessibilityValue() as? String, !value.isEmpty { result.append(value) }
                queue.append(contentsOf: accessible.accessibilityChildren()?.compactMap { $0 as? NSObject } ?? [])
            }
            if let view = next as? NSView { queue.append(contentsOf: view.subviews) }
            if let window = next as? NSWindow, let content = window.contentView { queue.append(content) }
        }
        return result
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
        #expect(texts(in: mounted.window).contains(title))
    }

    @Test(arguments: [1000.0, 1100.0, 1279.0, 1280.0, 1600.0], [false, true])
    func givenALongTitleAndChips_whenTheWindowIsAnyMatrixWidth_thenThePrincipalStaysVisibleWithItsTitle(width: Double, collapsed: Bool) async {
        // given a 120 character title
        let mounted = await mount(width: width, collapsed: collapsed)
        defer { mounted.window.close() }
        let title = String(repeating: "Long title ", count: 11)
        _ = publish(mounted, title: title, notices: 3)

        // when
        await waitUntil { pump(mounted.window); return texts(in: mounted.window).contains(title) }

        // then the principal drew the title, and the toolbar kept its items
        #expect(texts(in: mounted.window).contains(title))
        #expect(mounted.window.toolbar?.visibleItems?.isEmpty == false)
    }

    @Test func givenTheContentIsCleared_whenTheHolderEmpties_thenTheContextTitleReturns() async {
        // given
        let mounted = await mount(width: 1300)
        defer { mounted.window.close() }
        let tag = publish(mounted, title: "Shown task title")
        await waitUntil { pump(mounted.window); return texts(in: mounted.window).contains("Shown task title") }

        // when
        mounted.coordinator.topBar.clear(tag: tag)
        let title = M04ToolbarEvidence.contextTitle(mounted.coordinator)
        await waitUntil { pump(mounted.window); return texts(in: mounted.window).contains(title) }

        // then
        #expect(texts(in: mounted.window).contains(title))
    }
}
