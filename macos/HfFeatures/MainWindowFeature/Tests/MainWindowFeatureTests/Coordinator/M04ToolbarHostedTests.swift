import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - M04StateMatrixHostedTests toolbar evidence

extension M04StateMatrixHostedTests {
    @Test func givenShellWithoutToggleRemoval_whenHosted_thenSystemSidebarToggleIsPresent() async throws {
        // given / when — a bare split view in the production hosting shape, without the removal modifier.
        let identifiers = await M04ToolbarEvidence.controlToolbarIdentifiers()

        // then — a renamed or relocated system identifier must fail here, not pass the absence checks silently.
        #expect(identifiers.contains(where: M04ToolbarEvidence.isSystemSidebarToggleIdentifier), "Expected the system sidebar toggle among \(identifiers)")
    }

    @Test func givenExpandedShell_whenSidebarIsCollapsedAndExpandedAgain_thenSystemToggleStaysAbsent() async throws {
        // given
        _ = NSApplication.shared
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApplication.shared.accessibilitySetValue(previous, forAttribute: enhanced) }
        let fixture = makeFixture("shell")
        let coordinator = fixture.coordinator
        let size = NSSize(width: 1280, height: 800)
        let existing = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let controller = NSHostingController(rootView: MainWindowNavigationView(coordinator)
            .environment(\.hfReduceMotionOverride, true))
        controller.sceneBridgingOptions = .all
        let host = controller.view
        let window = M04ToolbarEvidence.makeWindow(controller, size: size)
        defer {
            for popup in NSApplication.shared.windows where !existing.contains(ObjectIdentifier(popup)) && popup !== window {
                popup.orderOut(nil)
                popup.close()
            }
            window.contentViewController = nil
            window.close()
        }
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            return NSApp.isActive && (window.isKeyWindow || window.isMainWindow)
                && contains("Collapse sidebar", in: window) && M04ToolbarEvidence.isPopulated(window)
        }
        await DisplayFrames.waitForPresentedFrame()
        try assertToolbarOwnsOnlyTheContextTitle(window, coordinator: coordinator, name: "expanded")

        // when — the public accessibility press collapses the sidebar to the rail.
        let collapse = try #require(tree(window).first { matches($0, "Collapse sidebar") && M04ToolbarEvidence.canPress($0) })
        #expect(M04ToolbarEvidence.press(collapse))
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            return contains("Navigation rail", in: window) && contains("Expand sidebar", in: window)
        }

        // then
        #expect(contains("Navigation rail", in: window))
        #expect(contains("Expand sidebar", in: window))
        await DisplayFrames.waitForPresentedFrame()
        try assertToolbarOwnsOnlyTheContextTitle(window, coordinator: coordinator, name: "collapsed")

        // when — the public accessibility press expands it again.
        let expand = try #require(tree(window).first { matches($0, "Expand sidebar") && M04ToolbarEvidence.canPress($0) })
        #expect(M04ToolbarEvidence.press(expand))
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let sidebar = tree(window).first { hasIdentifier($0, "main-window-sidebar") }
            let width = sidebar.flatMap(accessibilityFrame)?.width
            return width.map { abs($0 - 264) < 1 } == true && contains("Collapse sidebar", in: window)
        }

        // then — the sidebar is back at its fixed width and the system toggle never returned.
        let sidebars = tree(window).filter { hasIdentifier($0, "main-window-sidebar") }
        #expect(sidebars.count == 1)
        let sidebar = try #require(sidebars.first)
        let sidebarFrame = try #require(accessibilityFrame(sidebar))
        #expect(abs(sidebarFrame.width - 264) < 1)
        #expect(contains("Collapse sidebar", in: window))
        await DisplayFrames.waitForPresentedFrame()
        try assertToolbarOwnsOnlyTheContextTitle(window, coordinator: coordinator, name: "re-expanded")
    }

    /// The window toolbar carries the principal context title and no system sidebar toggle: the
    /// sidebar's own control is the only one. The principal item's identifier is generated, so
    /// it is identified by the title it presents.
    func assertToolbarOwnsOnlyTheContextTitle(_ window: NSWindow, coordinator: MainWindowNavigationCoordinatorMock,
                                              name: String) throws {
        let toolbar = try #require(window.toolbar, "Missing toolbar: \(name)")
        let identifiers = toolbar.items.map(\.itemIdentifier.rawValue)
        #expect(!toolbar.items.isEmpty, "Empty toolbar: \(name)")
        #expect(contains(M04ToolbarEvidence.contextTitle(coordinator), in: window), "Missing context title: \(name)")
        #expect(!toolbar.items.contains(where: M04ToolbarEvidence.isSystemSidebarToggle), "System sidebar toggle present: \(name) \(identifiers)")
        // Owner decision of 2026-11-06: the context title is centred on the window, not over the detail column.
        let title = tree(window).first { matches($0, M04ToolbarEvidence.contextTitle(coordinator)) && accessibilityFrame($0) != nil }
        let titleFrame = try #require(title.flatMap(accessibilityFrame), "Missing context title frame: \(name)")
        #expect(abs(titleFrame.midX - window.frame.midX) <= 16, "Context title off window centre: \(name) \(titleFrame) \(window.frame)")
    }
}
