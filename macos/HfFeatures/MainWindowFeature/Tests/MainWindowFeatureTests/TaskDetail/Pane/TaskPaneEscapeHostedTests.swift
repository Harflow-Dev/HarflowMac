import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - TaskPaneEscapeHostedTests

/// Escape for the standalone pane. The pane's only Escape route is a local key-down monitor, which sees events that go
/// through `NSApplication.sendEvent` (`.application`); an event sent straight to `NSWindow.sendEvent` (`.window`) skips
/// local monitors and must pass through. A suite of its own so it has its own runner time budget.
@MainActor @Suite(.serialized) struct TaskPaneEscapeHostedTests {
    static let conversation = TaskPaneHostedTests.conversation
    private let base = TaskPaneHostedTests()
    private static let overlayWidth: CGFloat = 800

    func seededStore(open: TaskPaneStateStore.OpenChoice? = .open, tab: TaskPaneStateStore.Tab = .events) -> TaskPaneStateStore {
        base.seededStore(open: open, tab: tab)
    }

    func mount(_ mock: TaskDetailViewModelMock, store: TaskPaneStateStore, width: CGFloat) async -> PaneHost {
        await base.mount(mock, store: store, width: width)
    }

    func press(_ host: PaneHost, _ label: String) throws { try base.press(host, label) }

    /// Activates the application and waits until it is active and the host window is key, re-asserting both while it
    /// waits, so the monitor's key-window guard is met. Failure messages carry `state(of:)` so an activation loss is visible.
    func activate(_ host: PaneHost) async {
        await host.page.settle {
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            if !host.page.window.isKeyWindow { host.page.window.makeKey() }
            return NSApp.isActive && host.page.window.isKeyWindow
        }
    }

    /// Failure evidence: offers a plain Escape straight to the monitor view's handler. `handler returns false` means the
    /// view holds the declining placeholder rather than the task view's handler.
    func handlerEvidence(_ host: PaneHost) -> String {
        guard let monitor = host.monitorViews.first else { return "no monitor view" }
        return monitor.handle() ? "handler returns true (real handler)" : "handler returns false (declining)"
    }

    /// The pane geometry a failure message reports: whether the host shows an overlay (only the pane at top level) or a
    /// split, and the measured widths.
    func geometry(of host: PaneHost) -> String {
        let top = (host.page.host.accessibilityChildren() ?? []).count
        return "top-level elements \(top), pane frame \(String(describing: host.paneFrame)), column \(String(describing: host.columnWidth)), "
            + "window \(host.page.window.frame.size)"
    }

    /// The activation state a failure message reports.
    func state(of host: PaneHost) -> String {
        let responder = String(describing: host.page.window.firstResponder.map { type(of: $0) })
        return "app active \(NSApp.isActive), key \(host.page.window.isKeyWindow), responder \(responder)"
    }

    /// Waits until the focused accessibility element carries `label`.
    func focusLands(on label: String, _ host: PaneHost) async -> Bool {
        await host.page.settle { host.focusedLabel == label }
        return host.focusedLabel == label
    }

    func overlay(_ mock: TaskDetailViewModelMock = PaneMocks.running(), store: TaskPaneStateStore) async -> PaneHost {
        let host = await mount(mock, store: store, width: Self.overlayWidth)
        await activate(host)
        return host
    }

    // MARK: - Closing

    @Test func givenAnOverlayThePersonOpenedWithNothingFocused_whenEscapeIsPressed_thenItClosesAndTheStoreReadsClosed() async throws {
        // given — a pane freshly mounted open, before any later update has refreshed its monitor
        let store = seededStore()
        let host = await overlay(store: store)
        defer { host.close() }
        #expect(host.focusedLabel?.isEmpty ?? true)
        let monitor = try #require(host.monitorViews.first)
        #expect(monitor.isMonitoring, "a freshly mounted open pane is monitoring")

        // when
        host.sendEscape(via: .application)
        await host.page.settle { !host.hasPane }

        // then — through the local monitor
        #expect(!host.hasPane, "\(state(of: host)); \(geometry(of: host))")
        #expect(store.openChoice(for: Self.conversation) == .closed)
    }

    @Test func givenAnOverlayWithCapsLockOn_whenEscapeIsPressed_thenItCloses() async {
        // given
        let store = seededStore()
        let host = await overlay(store: store)
        defer { host.close() }

        // when
        host.sendEscape(via: .application, modifiers: .capsLock)
        await host.page.settle { !host.hasPane }

        // then — Caps Lock is not a modifier that disables Escape (local monitor)
        #expect(!host.hasPane, "\(state(of: host))")
        #expect(store.openChoice(for: Self.conversation) == .closed)
    }

    @Test func givenAPersistedOpenPaneOnRevisit_whenEscapeIsPressedWithNothingFocused_thenItCloses() async {
        // given — A is open by the person's earlier choice; the person visits B and comes back
        let store = TaskPaneStateStore()
        store.setOpenChoice(.open, for: "A")
        store.setOpenChoice(.closed, for: "B")
        let selection = TaskPaneHostedTests.PaneSelection()
        let mocks = ["A": PaneMocks.running(), "B": PaneMocks.running()]
        let host = PaneHost(TaskPaneHostedTests.PaneSwitchHarness(selection: selection, store: store, mocks: mocks),
                            size: CGSize(width: Self.overlayWidth, height: 700))
        defer { host.close() }
        await host.page.settle { host.hasPane }
        selection.current = "B"
        await host.page.settle { !host.hasPane }
        selection.current = "A"
        await host.page.settle { host.hasPane }
        await activate(host)
        #expect(host.hasPane)
        #expect(host.focusedLabel?.isEmpty ?? true)

        // when
        host.sendEscape(via: .application)
        await host.page.settle { !host.hasPane }

        // then
        #expect(!host.hasPane, "\(state(of: host))")
        #expect(store.openChoice(for: "A") == .closed)
    }

    @Test(arguments: [("1 notice", TaskPaneStateStore.FactsGroup.notices, "Notices"),
                      ("Show supervision details", .continuity, "Continuity")])
    func givenARevealWithFocusInTheGroup_whenEscapeIsPressedTwice_thenTheFirstLeavesTheGroupForTheOriginAndTheNextClosesThePane(
        origin: String, group: TaskPaneStateStore.FactsGroup, title: String
    ) async throws {
        for width in [1280.0, 800.0] {
            // given
            let store = seededStore(open: .closed, tab: .artifacts)
            let host = await mount(PaneMocks.continuity(notices: ["A notice."]), store: store, width: width)
            defer { host.close() }
            await activate(host)
            try press(host, origin)
            await host.page.settle { host.focusedLabel?.hasPrefix(title) == true }
            let context = "local monitor at \(width)"
            #expect(store.expandedGroups(for: Self.conversation).contains(group), "\(context)")
            #expect(host.focusedLabel?.hasPrefix(title) == true, "\(context)")

            // when — first Escape
            host.sendEscape(via: .application)

            // then — focus leaves the group and lands on the control that revealed it; the pane stays
            let landed = await focusLands(on: origin, host)
            #expect(landed, "\(context): \(state(of: host)); focus is \(String(describing: host.focusedLabel)), expected \(origin)")
            #expect(host.hasPane, "\(context)")
            #expect(store.openChoice(for: Self.conversation) == .open, "\(context)")
            #expect(store.expandedGroups(for: Self.conversation).contains(group), "\(context)")

            // when — second Escape
            host.sendEscape(via: .application)
            await host.page.settle { !host.hasPane }

            // then — the revealed pane closes and focus is back on the origin
            #expect(!host.hasPane, "\(context): \(state(of: host))")
            #expect(store.openChoice(for: Self.conversation) == .closed, "\(context)")
            let stayed = await focusLands(on: origin, host)
            #expect(stayed, "\(context): after the close focus is \(String(describing: host.focusedLabel)), expected \(origin)")
        }
    }

    @Test(arguments: [("1 notice", "Notices"), ("Show supervision details", "Continuity")])
    func givenARevealedPane_whenClosedWithTheCloseButton_thenFocusLandsOnTheOrigin(origin: String, title: String) async throws {
        // given
        let store = seededStore(open: .closed, tab: .artifacts)
        let host = await mount(PaneMocks.continuity(notices: ["A notice."]), store: store, width: 1280)
        defer { host.close() }
        await activate(host)
        try press(host, origin)
        await host.page.settle { host.focusedLabel?.hasPrefix(title) == true }
        #expect(host.focusedLabel?.hasPrefix(title) == true)

        // when
        try press(host, "Close right pane")
        await host.page.settle { !host.hasPane }

        // then
        #expect(!host.hasPane)
        let landed = await focusLands(on: origin, host)
        #expect(landed, "after the close button focus is \(String(describing: host.focusedLabel)), expected \(origin)")
    }

    // MARK: - The window path passes through

    @Test func givenAnOverlayWithNothingFocused_whenEscapeIsSentStraightToTheWindow_thenItPassesThroughAndThePaneStays() async {
        // given
        let store = seededStore()
        let host = await overlay(store: store)
        defer { host.close() }

        // when
        host.sendEscape(via: .window)
        await host.pump(30)

        // then
        #expect(host.hasPane)
        #expect(store.openChoice(for: Self.conversation) == .open)
    }

    @Test func givenAnOverlay_whenEscapeVariantsAreSentStraightToTheWindow_thenTheyAllPassThrough() async throws {
        // given
        let store = seededStore()
        let host = await overlay(store: store)
        defer { host.close() }
        let other = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.orderFront(nil)
        defer { other.close() }
        host.page.window.makeKey()

        // when / then
        host.sendEscape(via: .window, modifiers: .shift)
        await host.pump(15)
        #expect(host.hasPane, "Shift+Escape")
        host.sendEscape(via: .window, isRepeat: true)
        await host.pump(15)
        #expect(host.hasPane, "a repeated Escape")
        host.sendEscape(via: .window, windowNumber: other.windowNumber)
        await host.pump(15)
        #expect(host.hasPane, "Escape for another window")
        #expect(store.openChoice(for: Self.conversation) == .open)
    }

    // MARK: - Escape is not taken

    @Test func givenAModifierOrARepeat_whenEscapeIsPressed_thenThePaneStaysAndTheHandlerNeverRuns() async throws {
        // given
        let store = seededStore()
        let host = await overlay(store: store)
        defer { host.close() }
        let monitor = try #require(host.monitorViews.first)
        var calls = 0
        // SwiftUI may refresh the handler between pumps, so it is set again immediately before each key press.
        func send(modifiers: NSEvent.ModifierFlags = [], isRepeat: Bool = false) {
            monitor.handle = { calls += 1; return true }
            host.sendEscape(via: .application, modifiers: modifiers, isRepeat: isRepeat)
        }

        // when / then — end to end through the local monitor
        send(isRepeat: true)
        for modifier: NSEvent.ModifierFlags in [.command, .shift, .option, .control, [.shift, .capsLock]] { send(modifiers: modifier) }
        #expect(calls == 0)
        #expect(host.hasPane)
        #expect(store.openChoice(for: Self.conversation) == .open)

        // when — a plain Escape does reach the handler
        send()
        #expect(calls == 1)
    }

    @Test func givenShiftOrCommand_whenEscapeIsPressedOnAnOverlay_thenItPassesThroughToTheRealHandler() async {
        for modifier: NSEvent.ModifierFlags in [.shift, .command] {
            // given
            let store = seededStore()
            let host = await overlay(store: store)
            defer { host.close() }

            // when
            host.sendEscape(via: .application, modifiers: modifier)
            await host.pump(30)

            // then
            #expect(host.hasPane, "modifier \(modifier.rawValue)")
            #expect(store.openChoice(for: Self.conversation) == .open)
        }
    }

    @Test func givenAComposerTextEditorHasFocus_whenEscapeIsPressed_thenTheOverlayStaysOpen() async throws {
        // given
        let store = seededStore()
        let host = await overlay(store: store)
        defer { host.close() }
        let field = try #require(host.allViews(host.page.host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        #expect(host.page.window.makeFirstResponder(field))
        #expect(host.page.window.firstResponder is NSText)

        // when
        host.sendEscape(via: .application)
        await host.pump(30)

        // then
        #expect(host.hasPane)
        #expect(store.openChoice(for: Self.conversation) == .open)
    }

    @Test func givenAnotherTextFieldHasFocus_whenEscapeIsPressed_thenTheOverlayStaysOpen() async throws {
        // given
        let store = seededStore()
        let host = await overlay(store: store)
        defer { host.close() }
        let extra = NSTextField(string: "")
        extra.frame = CGRect(x: 4, y: 4, width: 120, height: 22)
        host.page.host.addSubview(extra)
        defer { extra.removeFromSuperview() }
        #expect(host.page.window.makeFirstResponder(extra))
        #expect(host.page.window.firstResponder is NSText)

        // when
        host.sendEscape(via: .application)
        await host.pump(30)

        // then
        #expect(host.hasPane)
        #expect(store.openChoice(for: Self.conversation) == .open)
    }

    @Test func givenASheetIsAttached_whenEscapeIsPressed_thenThePaneIsNotClosed() async throws {
        // given
        let store = seededStore()
        let host = await overlay(store: store)
        defer { host.close() }
        let sheet = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        host.page.window.beginSheet(sheet) { _ in }
        await host.page.settle { host.page.window.attachedSheet != nil }
        #expect(host.page.window.attachedSheet != nil)

        // when
        host.sendEscape(via: .application)
        await host.pump(30)

        // then
        #expect(host.hasPane)
        #expect(store.openChoice(for: Self.conversation) == .open)
        host.page.window.endSheet(sheet)
        sheet.close()
    }

    @Test func givenTheEventTargetsAnotherWindow_whenEscapeIsPressed_thenThePaneIsNotClosed() async throws {
        // given
        let store = seededStore()
        let host = await overlay(store: store)
        defer { host.close() }
        let other = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.orderFront(nil)
        defer { other.close() }
        host.page.window.makeKey()

        // when — the host window stays key but the event names the other window
        host.sendEscape(via: .application, windowNumber: other.windowNumber)
        await host.pump(30)

        // then
        #expect(host.hasPane)
        #expect(store.openChoice(for: Self.conversation) == .open)
    }

    @Test func givenTheWindowIsNotKey_whenEscapeIsPressed_thenThePaneIsNotClosed() async throws {
        // given
        let store = seededStore()
        let host = await overlay(store: store)
        defer { host.close() }
        let other = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.makeKeyAndOrderFront(nil)
        defer { other.close() }
        await host.page.settle { !host.page.window.isKeyWindow }
        #expect(!host.page.window.isKeyWindow)

        // when
        host.sendEscape(via: .application)
        await host.pump(30)

        // then
        #expect(host.hasPane)
        #expect(store.openChoice(for: Self.conversation) == .open)
    }

    @Test func givenAnotherKey_whenPressedOnAnOverlay_thenThePaneIsNotClosed() async throws {
        // given
        let store = seededStore()
        let host = await overlay(store: store)
        defer { host.close() }
        let event = try #require(host.keyEvent(keyCode: 36, characters: "\r"))

        // when
        NSApp.sendEvent(event)
        await host.pump(20)

        // then
        #expect(host.hasPane)
    }

    @Test func givenAPaneThePersonOpenedAtSplitWidth_whenEscapeIsPressed_thenItStaysOpen() async {
        // given
        let store = seededStore()
        let host = await mount(PaneMocks.running(), store: store, width: 1280)
        defer { host.close() }
        await activate(host)

        // when
        host.sendEscape(via: .application)
        await host.pump(30)

        // then
        #expect(host.hasPane)
        #expect(store.openChoice(for: Self.conversation) == .open)
    }

    // MARK: - Focus regions

    /// A native button outside the task detail region and one inside it, beside the standalone view.
    private struct RegionHarness: NSViewRepresentable {
        let button: NSButton
        func makeNSView(context: Context) -> NSButton { button }
        func updateNSView(_ view: NSButton, context: Context) {}
    }

    private func regionHost(store: TaskPaneStateStore, outside: NSButton) async -> PaneHost {
        let view = HStack(spacing: 0) {
            RegionHarness(button: outside).frame(width: 160, height: 40)
            PaneMocks.standalone(PaneMocks.running(), store: store)
        }
        let host = PaneHost(view, size: CGSize(width: 1000, height: 700))
        await host.page.settle { host.hasPane }
        await activate(host)
        return host
    }

    @Test func givenAFocusedNativeControlOutsideTheTaskDetailRegion_whenEscapeIsPressed_thenItKeepsItsEscape() async throws {
        // given — a 1000 wide window less a 160 wide control column leaves an overlay-width detail region
        let store = seededStore()
        let outside = NSButton(title: "Outside", target: nil, action: nil)
        let host = await regionHost(store: store, outside: outside)
        defer { host.close() }
        #expect(host.hasPane)
        #expect(host.page.window.makeFirstResponder(outside))
        #expect(host.page.window.firstResponder === outside)

        // when
        host.sendEscape(via: .application)
        await host.pump(30)

        // then
        #expect(host.hasPane)
        #expect(store.openChoice(for: Self.conversation) == .open)
    }

    @Test func givenAFocusedNativeControlInsideTheTaskDetailRegion_whenEscapeIsPressed_thenTheOverlayCloses() async throws {
        // given
        let store = seededStore()
        let outside = NSButton(title: "Outside", target: nil, action: nil)
        let host = await regionHost(store: store, outside: outside)
        defer { host.close() }
        let inside = NSButton(title: "Inside", target: nil, action: nil)
        inside.frame = CGRect(x: 300, y: 300, width: 80, height: 24)
        host.page.host.addSubview(inside)
        defer { inside.removeFromSuperview() }
        #expect(host.page.window.makeFirstResponder(inside))
        #expect(host.page.window.firstResponder === inside)

        // when
        host.sendEscape(via: .application)
        await host.page.settle { !host.hasPane }

        // then
        #expect(!host.hasPane)
        #expect(store.openChoice(for: Self.conversation) == .closed)
    }

    // MARK: - Menus

    @MainActor private final class MenuProbe {
        let menu: NSMenu
        let escape: NSEvent
        private(set) var escapePosted = false
        private(set) var forcedClose = false

        init(menu: NSMenu, escape: NSEvent) {
            self.menu = menu
            self.escape = escape
        }

        func postEscape() {
            escapePosted = true
            NSApp.postEvent(escape, atStart: true)
        }

        func forceClose() {
            forcedClose = true
            menu.cancelTracking()
        }
    }

    @Test func givenAMenuIsOpen_whenEscapeIsPressedOnAnOverlay_thenTheMenuClosesAndThePaneStays() async throws {
        // given
        let store = seededStore()
        let host = await overlay(store: store)
        defer { host.close() }
        let menu = NSMenu(title: "Probe")
        menu.addItem(withTitle: "One", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Two", action: nil, keyEquivalent: "")
        let probe = MenuProbe(menu: menu, escape: try #require(host.keyEvent()))
        let post = Timer(timeInterval: 0.4, repeats: false) { _ in MainActor.assumeIsolated { probe.postEscape() } }
        let guardTimer = Timer(timeInterval: 2.5, repeats: false) { _ in MainActor.assumeIsolated { probe.forceClose() } }
        RunLoop.main.add(post, forMode: .common)
        RunLoop.main.add(guardTimer, forMode: .common)

        // when — `popUp` returns when the menu's tracking loop ends
        _ = menu.popUp(positioning: nil, at: CGPoint(x: 20, y: 20), in: host.page.host)
        post.invalidate()
        guardTimer.invalidate()
        await host.pump(20)

        // then
        print("MENU escapePosted=\(probe.escapePosted) forcedClose=\(probe.forcedClose)")
        #expect(probe.escapePosted, "the menu's tracking loop ran long enough to receive the key")
        #expect(host.hasPane)
        #expect(store.openChoice(for: Self.conversation) == .open)
        // Recorded: `forcedClose` is true when the synthetic Escape did not end tracking itself.
        #expect(!probe.forcedClose, "the posted Escape closed the menu")
    }

    // MARK: - Monitor lifetime

    @Test func givenTheMonitorView_whenThePaneClosesAndTheViewLeavesItsWindow_thenItNoLongerActsOnEscape() async throws {
        // given — installation is observed through the monitor view's `isMonitoring`, and the behaviour through whether an
        // inactive or detached monitor view ever offers Escape to its handler.
        let store = seededStore()
        let host = await overlay(store: store)
        let monitor = try #require(host.monitorViews.first)
        #expect(monitor.isMonitoring, "right after a fresh open overlay mounts")
        var calls = 0
        monitor.handle = { calls += 1; return true }
        host.sendEscape(via: .application)
        #expect(calls == 1, "an active monitor in the key window offers a plain Escape to its handler")

        // when — the pane closes
        monitor.handle = { calls += 1; return true }
        try press(host, "Close right pane")
        await host.page.settle { !host.hasPane }

        // then — closed: not monitoring, and neither path reaches a handler
        #expect(!host.hasPane)
        #expect(!monitor.isMonitoring, "after the pane closes")
        let before = calls
        host.sendEscape(via: .application)
        host.sendEscape(via: .window)
        #expect(calls == before)
        #expect(store.openChoice(for: Self.conversation) == .closed)
        host.close()

        // when — a second host's view leaves the window while its pane is open
        let second = await overlay(store: seededStore())
        let detached = try #require(second.monitorViews.first)
        #expect(detached.isMonitoring)
        var detachedCalls = 0
        detached.handle = { detachedCalls += 1; return true }
        let window = second.page.window
        second.close()

        // then
        #expect(detached.window == nil)
        #expect(!detached.isMonitoring, "after the view leaves its window")
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: "\u{1B}",
                                        charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53) {
            NSApp.sendEvent(event)
        }
        #expect(detachedCalls == 0)
    }
}
