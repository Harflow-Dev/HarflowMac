import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Observation
import SwiftUI
import Testing

// MARK: - TaskPaneHostedTests + mounts and accessibility

/// The unchanged group and embedded mounts, and the pane's accessibility. An extension so it stays one serialized suite.
extension TaskPaneHostedTests {

    // MARK: - Group and embedded mounts

    private func legacyMount(_ chrome: TaskDetailChrome, width: CGFloat) async -> PaneHost {
        let host = PaneHost(TaskDetailView(PaneMocks.running(notices: ["n1"]), chrome: chrome, transcriptStyle: .standard)
            .environment(\.hfReduceMotionOverride, true), size: CGSize(width: width, height: 700))
        await host.page.settle { host.page.element("Task snapshot facts and actions") != nil }
        return host
    }

    @Test(arguments: [(TaskDetailChrome.group, 320.0), (.embedded, 280.0)])
    func givenTheGroupOrEmbeddedMount_whenMounted_thenTheLegacyPaneKeepsItsOwnWidthWithNoRightPane(
        chrome: TaskDetailChrome, paneWidth: CGFloat
    ) async throws {
        // given / when
        let host = await legacyMount(chrome, width: 1000)
        defer { host.close() }

        // then
        #expect(!host.hasPane)
        #expect(host.page.element("Close right pane") == nil)
        #expect(host.page.element("Artifacts") == nil)
        let facts = try #require(host.page.element("Task snapshot facts and actions"))
        let frame = try #require(host.page.frame(facts))
        // The disclosure's frame includes its leading affordance, so allow a few points either side of the pane edge.
        #expect(frame.minX >= 1000 - paneWidth - 10, "legacy pane content starts at \(frame.minX), pane is \(paneWidth) wide")
        #expect(frame.minX <= 1000 - paneWidth + 30, "legacy pane content starts at \(frame.minX), pane is \(paneWidth) wide")
        #expect(frame.maxX <= 1000 + 1)
        #expect(host.page.element("Public normalized events · bounded record window") != nil)
    }

    @Test func givenTheEmbeddedMount_whenTheInspectorTogglePressed_thenEventsHideAndShowWithEventsExpanded() async throws {
        // given
        let host = await legacyMount(.embedded, width: 1000)
        defer { host.close() }
        let events = "Public normalized events · bounded record window"
        #expect(host.page.element(events) != nil)

        // when
        try press(host, "Hide event details")
        await host.page.settle { host.page.element(events) == nil }

        // then — the legacy pane keeps its width; its events content is what the flag controls
        #expect(host.page.element(events) == nil)
        #expect(host.page.element("Show event details") != nil)

        // when
        try press(host, "Show event details")
        await host.page.settle { host.page.element(events) != nil }

        // then
        #expect(host.page.element(events) != nil)
    }

    @Test func givenTheGroupMount_whenResizedBelowNineHundred_thenNothingAdaptive() async {
        // given
        let host = await legacyMount(.group, width: 1200)
        defer { host.close() }

        // when
        host.resize(to: CGSize(width: 700, height: 700))
        await host.pump(30)

        // then
        #expect(!host.hasPane)
        #expect(host.page.element("Task snapshot facts and actions") != nil)
    }

    // MARK: - Accessibility

    @Test func givenTheEventsTab_whenInspected_thenEveryFactsGroupHeaderIsAButtonAnnouncingItsExpansion() async throws {
        // given
        let host = await mount(PaneMocks.continuity(notices: ["A notice."]), store: seededStore(), width: 1280)
        defer { host.close() }

        // when
        var seen = Set<ObjectIdentifier>()
        let headers = host.allElements.filter {
            let value = host.string($0, "accessibilityValue")
            return (value == "Expanded" || value == "Collapsed") && seen.insert(ObjectIdentifier($0)).inserted
        }

        // then
        let labels = headers.compactMap { host.string($0, "accessibilityLabel") }
        #expect(labels.contains("Task"))
        #expect(labels.contains("What was enforced") || labels.contains("Notices, 1"))
        #expect(labels.contains("Continuity"))
        #expect(labels.contains("Reported result and usage"))
        for header in headers {
            #expect(host.string(header, "accessibilityRole") == "AXButton", "\(host.string(header, "accessibilityLabel") ?? "?") is not a button")
            #expect(host.page.frame(header) != nil)
        }
    }

    @Test func givenAGroupHeader_whenPressed_thenItsAnnouncedValueAndTheStoreFlip() async throws {
        // given
        let store = seededStore()
        let host = await mount(PaneMocks.continuity(notices: ["A notice."]), store: store, width: 1280)
        defer { host.close() }
        #expect(host.headerValue("Continuity") == "Collapsed")

        // when
        let header = try #require(host.header("Continuity"))
        #expect(host.page.press(header))
        await host.page.settle { host.headerValue("Continuity") == "Expanded" }

        // then
        #expect(host.headerValue("Continuity") == "Expanded")
        #expect(store.expandedGroups(for: Self.conversation).contains(.continuity))

        // when
        let again = try #require(host.header("Continuity"))
        #expect(host.page.press(again))
        await host.page.settle { host.headerValue("Continuity") == "Collapsed" }

        // then
        #expect(host.headerValue("Continuity") == "Collapsed")
        #expect(!store.expandedGroups(for: Self.conversation).contains(.continuity))
    }

    @Test func givenTheSplitPane_whenInspected_thenItIsLabelledTaskDetailsAndExposesTheTabsAndClose() async {
        // given
        let host = await mount(PaneMocks.running(), store: seededStore(), width: 1280)
        defer { host.close() }

        // when / then
        for label in ["Task details", "Artifacts", "Events", "Close right pane"] {
            #expect(host.page.element(label) != nil, "missing \(label)")
        }
    }

    // MARK: - Focus return on the legacy mounts

    /// The embedded mount has an in-view inspector toggle, so it stands in for Group here: the group mount's toggle lives in
    /// the window toolbar, whose controls cannot be pressed in a hosted window. Both share the same layout and the same
    /// `eventsExpanded` focus-return code in `legacyLayout`.
    @Test func givenTheLegacyPaneRevealedByDetails_whenTheEventsPaneIsClosed_thenFocusLeavesTheSupervisionHeading() async throws {
        // given
        let host = PaneHost(TaskDetailView(PaneMocks.continuity(), chrome: .embedded, transcriptStyle: .standard)
            .environment(\.hfReduceMotionOverride, true), size: CGSize(width: 1000, height: 700))
        defer { host.close() }
        await host.page.settle { host.page.element("Show supervision details") != nil }
        activate(host)
        await host.page.settle { host.page.window.isKeyWindow }

        // when — Details reveals the supervision facts, then the events pane is closed
        try press(host, "Show supervision details")
        // Details also moves focus to the supervision heading in the pane, a moment later; closing waits for that.
        await host.page.settle { host.focusedLabel == "Supervision" }
        try press(host, "Hide event details")
        await host.page.settle { host.page.element("Show event details") != nil }

        // then — focus left the supervision heading. In this host (no Full Keyboard Access) a programmatic focus request does
        // not land on the plain, non-focusable origin button the legacy mounts keep, so focus is not asserted on it.
        await host.page.settle { host.focusedLabel != "Supervision" }
        #expect(host.focusedLabel != "Supervision", "focus after closing the events pane: \(String(describing: host.focusedLabel))")
    }

    @Test func givenTheLegacyPaneClosedWithoutDetails_whenTheEventsPaneIsClosed_thenFocusIsUnchanged() async throws {
        // given
        let host = PaneHost(TaskDetailView(PaneMocks.continuity(), chrome: .embedded, transcriptStyle: .standard)
            .environment(\.hfReduceMotionOverride, true), size: CGSize(width: 1000, height: 700))
        defer { host.close() }
        await host.page.settle { host.page.element("Hide event details") != nil }
        activate(host)
        await host.page.settle { host.page.window.isKeyWindow }
        let before = host.focusedLabel

        // when
        try press(host, "Hide event details")
        await host.page.settle { host.page.element("Show event details") != nil }
        await host.pump(20)

        // then — nothing happens (fixed wait): no Details request was made, so focus stays where it was
        #expect(host.focusedLabel == before, "focus was \(String(describing: before)), now \(String(describing: host.focusedLabel))")
    }
}
