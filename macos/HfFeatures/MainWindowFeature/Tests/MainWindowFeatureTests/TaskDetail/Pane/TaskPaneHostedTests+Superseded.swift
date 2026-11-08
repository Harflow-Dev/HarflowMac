import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Observation
import SwiftUI
import Testing

// MARK: - TaskPaneHostedTests + superseded reveals

/// Two reveals in quick succession: the newest wins end to end and no stale focus lands afterwards.
extension TaskPaneHostedTests {
    @Test func givenTwoRevealsInQuickSuccession_whenTheSecondIsNewest_thenItsGroupHoldsFocusAndStaysThere() async throws {
        // given
        let store = seededStore(open: .closed, tab: .artifacts)
        let host = await mount(PaneMocks.continuity(notices: ["A notice."]), store: store, width: 1280)
        defer { host.close() }
        activate(host)
        await host.page.settle { host.page.window.isKeyWindow }

        // when — both origin controls are in the column, so both presses land before the pane renders
        try press(host, "1 notice")
        try press(host, "Show supervision details")
        await host.page.settle { host.focusedLabel?.hasPrefix("Continuity") == true }

        // then
        #expect(host.focusedLabel?.hasPrefix("Continuity") == true)
        #expect(store.expandedGroups(for: Self.conversation) == [.notices, .continuity])
        #expect(store.selectedTab(for: Self.conversation) == .events)

        // when / then — nothing earlier lands afterwards (nothing-happened check, so a fixed wait)
        await host.pump(30)
        #expect(host.focusedLabel?.hasPrefix("Continuity") == true, "focus is now \(String(describing: host.focusedLabel))")
    }

    @Test func givenARevealThenAClose_whenTheCloseLandsFirst_thenNoFocusEntersAGroup() async throws {
        // given
        let store = seededStore(open: .closed, tab: .artifacts)
        let host = await mount(PaneMocks.running(notices: ["A notice."]), store: store, width: 1280)
        defer { host.close() }
        activate(host)

        // when — the person closes straight after the reveal, before the pane renders
        try press(host, "1 notice")
        store.setOpenChoice(.closed, for: Self.conversation)
        await host.page.settle { !host.hasPane }

        // then — a stale focus request must not land in a group of a pane that is not there (fixed wait: nothing happens)
        await host.pump(30)
        #expect(!host.hasPane)
        #expect(host.focusedLabel?.hasPrefix("Notices") != true)
        #expect(store.openChoice(for: Self.conversation) == .closed)
    }

    @Test func givenARevealThenATabSwitch_whenTheSwitchLandsFirst_thenNoFocusEntersAGroup() async throws {
        // given
        let store = seededStore(open: .closed, tab: .artifacts)
        let host = await mount(PaneMocks.running(notices: ["A notice."]), store: store, width: 1280)
        defer { host.close() }
        activate(host)

        // when
        try press(host, "1 notice")
        store.setSelectedTab(.artifacts, for: Self.conversation)
        await host.page.settle { host.hasPane && host.header("Task") == nil }

        // then — fixed wait: nothing happens
        await host.pump(30)
        #expect(host.header("Task") == nil)
        #expect(host.focusedLabel?.hasPrefix("Notices") != true)
    }
}
