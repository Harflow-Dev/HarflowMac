import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - TaskPaneEscapeHostedTests + toolbar origin ownership

extension TaskPaneEscapeHostedTests {
    @Test func givenKeyboardFocusReturnsToTheRevealingToolbarItem_whenSecondEscapeArrives_thenTheRevealedPaneCloses() async throws {
        // given — real toolbar views force a native keyboard responder, independently of SwiftUI's chip fallback.
        let fixture = ToolbarEscapeFixture()
        defer { fixture.host.close() }
        await activate(fixture.host)
        await fixture.host.page.settle { fixture.origin.window === fixture.host.page.window }
        let controller = TaskPaneController(store: TaskPaneStateStore(), conversationID: "toolbar-ownership")
        controller.updateContainerWidth(1280)
        controller.revealFacts(group: .notices, origin: .chipNotices)
        fixture.monitor.toolbarOriginIdentifier = controller.revealOrigin.flatMap(TaskPaneChipFocus.toolbarIdentifier(for:))
        var groupFocused = true
        var calls = 0
        fixture.monitor.handle = {
            calls += 1
            let outcome = controller.handleEscape(groupFocused: groupFocused)
            if case .leftFactsGroup = outcome {
                groupFocused = false
                fixture.host.page.window.makeFirstResponder(fixture.origin)
            }
            if case .ignored = outcome { return false }
            return true
        }
        #expect(fixture.host.page.window.makeFirstResponder(fixture.host.page.host))

        // when — first Escape leaves facts and lands on the native origin, second closes the pane.
        fixture.host.sendEscape()
        #expect(calls == 1)
        #expect(controller.isOpen)
        #expect(fixture.host.page.window.firstResponder === fixture.origin)
        #expect(fixture.host.page.window.toolbar?.visibleItems?.contains { $0.view === fixture.origin } == true)
        fixture.host.sendEscape()

        // then
        #expect(calls == 2)
        #expect(!controller.isOpen)
    }

    @Test(arguments: ["unrelated", "changed", "absent"])
    func givenToolbarFocusOutsideTheCurrentRevealOrigin_whenEscapeArrives_thenTheMonitorPassesItThrough(scenario: String) async throws {
        // given
        let fixture = ToolbarEscapeFixture()
        defer { fixture.host.close() }
        await activate(fixture.host)
        await fixture.host.page.settle { fixture.origin.window === fixture.host.page.window }
        fixture.monitor.toolbarOriginIdentifier = scenario == "absent" ? nil
            : scenario == "changed" ? ToolbarEscapeFixture.otherID : ToolbarEscapeFixture.originID
        var calls = 0
        fixture.monitor.handle = { calls += 1; return true }
        let target = scenario == "unrelated" ? fixture.other : fixture.origin
        #expect(fixture.host.page.window.makeFirstResponder(target))
        #expect(fixture.host.page.window.firstResponder === target)

        // when
        fixture.host.sendEscape()

        // then
        #expect(calls == 0)
        #expect(fixture.host.page.window.firstResponder === target)
    }
}

// MARK: - ToolbarEscapeFixture

/// Two real toolbar items and an active content-region monitor, without the OS-dependent SwiftUI focus return.
@MainActor private final class ToolbarEscapeFixture: NSObject, NSToolbarDelegate {
    static let originID = "task-detail.chip.notices"
    static let otherID = "task-detail.chip.access"
    let host = PaneHost(Color.clear, size: CGSize(width: 1280, height: 700))
    let origin = ToolbarEscapeResponder(frame: CGRect(x: 0, y: 0, width: 80, height: 24))
    let other = ToolbarEscapeResponder(frame: CGRect(x: 0, y: 0, width: 80, height: 24))
    let monitor = PaneEscapeMonitor.MonitorView()

    override init() {
        super.init()
        let toolbar = NSToolbar(identifier: "header-cleanup.escape-ownership")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        host.page.window.toolbar = toolbar
        monitor.frame = host.page.host.bounds
        monitor.autoresizingMask = [.width, .height]
        host.page.host.addSubview(monitor)
        monitor.setActive(true)
    }

    func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [NSToolbarItem.Identifier(Self.originID), NSToolbarItem.Identifier(Self.otherID)]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(_: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar _: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = identifier.rawValue == Self.originID ? origin : other
        return item
    }
}

// MARK: - ToolbarEscapeResponder

@MainActor private final class ToolbarEscapeResponder: NSView {
    override var acceptsFirstResponder: Bool { true }
}
