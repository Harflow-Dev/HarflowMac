import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - SummaryEntryPaneMocks

/// A finished task with a settled duration, usage and a reported summary. With `entry` the mock claims the
/// transcript's Summary entry shows and carries it as the feed's last row.
@MainActor enum SummaryEntryPaneMocks {
    static let summary = "Fixed the retry path and added a regression test for the slot release."

    static func done(entry: Bool, summaryText: String = SummaryEntryPaneMocks.summary) -> TaskDetailViewModelMock {
        let mock = PaneMocks.done(exit: 0)
        var raw = mock.task!.raw
        raw["duration_seconds"] = .number(1260)
        raw["num_turns"] = .number(7)
        raw["usage"] = .object(["input_tokens": .number(12_000), "output_tokens": .number(3_400)])
        raw["total_cost_usd"] = .number(0.0123)
        raw["summary"] = .string(summaryText)
        let task = TaskInfo(.object(raw))!
        mock.task = task
        mock.summaryModel = SummaryPaneModel.build(task: task, summary: summaryText, events: [], eventsAvailability: .available)
        mock.summaryEntryShown = entry
        if entry {
            let model = mock.timelineModel
            let markdown = StreamingMarkdownState().updating(text: summaryText, isStreaming: false)
            let row = ActivityRow.summary(SummaryEntry(
                id: SummaryEntry.rowID(taskID: PaneMocks.taskID), taskID: PaneMocks.taskID, text: summaryText, markdown: markdown))
            mock.timelineModel = TimelinePaneModel(
                stepCountText: model.stepCountText, rows: model.rows, activityRows: model.activityRows + [row], start: model.start,
                emptyText: nil, subTaskStrip: nil, isLoading: false, liveStep: nil,
                updateToken: ActivityUpdateToken(rows: model.rows, liveStep: nil), history: EventHistoryState(hasMore: true))
        }
        return mock
    }

    static func turnsOnly() -> TaskDetailViewModelMock {
        unavailable(entry: false)
    }

    static func unavailable(entry: Bool) -> TaskDetailViewModelMock {
        let mock = done(entry: entry)
        var raw = mock.task!.raw
        raw["num_turns"] = .number(7)
        raw["duration_seconds"] = nil
        raw["usage"] = nil
        raw["total_cost_usd"] = nil
        if !entry { raw["summary"] = nil }
        let task = TaskInfo(.object(raw))!
        mock.task = task
        mock.summaryModel = SummaryPaneModel.build(task: task, summary: entry ? summary : nil, events: [], eventsAvailability: .available)
        mock.summaryEntryShown = entry
        return mock
    }
}

// MARK: - TaskPaneSummaryEntryHostedTests

/// The Events usage group with and without the transcript's Summary entry: heading, the hero and Result sections, the
/// Duration tile and the metric scope caption, and the group's expansion across the switch.
@MainActor @Suite(.serialized) struct TaskPaneSummaryEntryHostedTests {
    static let conversation = "conv"

    private func store() -> TaskPaneStateStore {
        let store = TaskPaneStateStore()
        store.setOpenChoice(.open, for: Self.conversation)
        store.setSelectedTab(.events, for: Self.conversation)
        store.setExpandedGroups([.usage], for: Self.conversation)
        return store
    }

    private func mount(_ mock: TaskDetailViewModelMock, store: TaskPaneStateStore,
                       size: CGSize = CGSize(width: 1280, height: 900)) async -> PaneHost {
        let host = PaneHost(PaneMocks.standalone(mock, store: store), size: size)
        await host.page.settle { host.hasPane && host.header("Reported") != nil }
        await host.pump(30)
        return host
    }

    /// Whether an accessibility element carrying `text` lies inside (`inPane`) or outside the right pane's frame.
    private func has(_ host: PaneHost, _ text: String, inPane: Bool = true) -> Bool {
        guard let pane = host.paneFrame else { return false }
        return host.allElements.contains { element in
            guard ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"].contains(where: {
                host.string(element, $0)?.contains(text) == true
            }), let frame = host.page.frame(element) else { return false }
            return pane.insetBy(dx: -2, dy: -2).contains(CGPoint(x: frame.midX, y: frame.midY)) == inPane
        }
    }

    private func matchingFrame(_ host: PaneHost, _ text: String, exact: Bool = false, inPane: Bool = true) -> CGRect? {
        guard let pane = host.paneFrame else { return nil }
        return host.allElements
.first { element in
            let matches = ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"].contains {
                guard let value = host.string(element, $0) else { return false }
                return exact ? value == text : value.contains(text)
            }
            guard matches, let frame = host.page.frame(element) else { return false }
            return pane.insetBy(dx: -2, dy: -2).contains(CGPoint(x: frame.midX, y: frame.midY)) == inPane
        }
.flatMap(host.page.frame)
    }

    private func isVisible(_ host: PaneHost, _ text: String, in scroll: NSScrollView, exact: Bool = false, inPane: Bool = true) -> Bool {
        guard let frame = matchingFrame(host, text, exact: exact, inPane: inPane) else { return false }
        let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
        return viewport.intersects(frame)
    }

    @Test func givenTheEntryIsShown_whenTheUsageGroupIsOpen_thenNoHeroNoResultAndAReportedUsageHeading() async {
        // given / when
        let host = await mount(SummaryEntryPaneMocks.done(entry: true), store: store())
        defer { host.close() }
        // then
        #expect(host.headerValue("Reported usage") == "Expanded")
        #expect(host.header("Reported result and usage") == nil)
        #expect(!has(host, "Done in"), "the hero headline must be hidden")
        #expect(!has(host, "Result"), "the Result section must be hidden")
        #expect(!has(host, SummaryEntryPaneMocks.summary), "the usage group must not repeat the summary")
        #expect(has(host, SummaryEntryPaneMocks.summary, inPane: false), "the transcript draws the summary")
    }

    @Test func givenTheEntryIsShown_whenTheUsageGroupIsOpen_thenTheDurationTileAndTheScopeCaptionStay() async {
        // given / when
        let host = await mount(SummaryEntryPaneMocks.done(entry: true), store: store())
        defer { host.close() }
        // then
        #expect(has(host, "Duration"))
        #expect(has(host, "Reported by current agent run"))
        #expect(has(host, "Input tokens"))
        #expect(has(host, "Output tokens"))
    }

    @Test func givenNoEntry_whenTheUsageGroupIsOpen_thenTheHeroAndTheResultStayUnderTheOriginalHeading() async {
        // given / when
        let host = await mount(SummaryEntryPaneMocks.done(entry: false), store: store())
        defer { host.close() }
        // then
        #expect(host.headerValue("Reported result and usage") == "Expanded")
        #expect(host.header("Reported usage") == nil)
        #expect(has(host, "Result"))
        #expect(has(host, SummaryEntryPaneMocks.summary))
        #expect(has(host, "Duration"))
        #expect(has(host, "Input tokens"))
        #expect(has(host, "Output tokens"))
        #expect(has(host, "Cost"))
    }

    @Test
    func givenCompactEventsWithEitherSummaryState_whenExpanded_thenFullContentUsesOnlyTheMainScrollAndThePublicEventsFooterRemainsReachable() async throws {
        let longResult = Array(repeating: "The full reported result remains in the expanded Events content.", count: 48).joined(separator: "\n\n")
            + "\n\nCOMPACT_EVENTS_FINAL_RESULT_MARKER"
        for size in [CGSize(width: 1000, height: 620), CGSize(width: 1280, height: 800)] {
            for entry in [false, true] {
                let host = await mount(SummaryEntryPaneMocks.done(entry: entry, summaryText: entry ? SummaryEntryPaneMocks.summary : longResult),
                                       store: store(), size: size)
                defer { host.close() }

                try await verifyCompactViewport(host, entry: entry, size: size)
            }
        }
    }

    private func verifyCompactViewport(_ host: PaneHost, entry: Bool, size: CGSize) async throws {
        #expect(host.paneScrollViews().count == 1, "\(Int(size.width))x\(Int(size.height)) should have only the pane's main scroll view")
        #expect(host.headerValue(entry ? "Reported usage" : "Reported result and usage") == "Expanded")
        let scroll = try #require(host.paneScrollViews().first)
        let document = try #require(scroll.documentView)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(abs(scroll.contentView.bounds.origin.y) <= 2, "The first observation starts at the outer scroll view's top")
        if entry {
            #expect(!isVisible(host, "Result", in: scroll, exact: true))
            #expect(!has(host, SummaryEntryPaneMocks.summary))
            #expect(has(host, SummaryEntryPaneMocks.summary, inPane: false))
        } else {
            #expect(isVisible(host, "Result", in: scroll, exact: true), "The result heading should be visible at the top")
            #expect(isVisible(host, "The full reported result remains", in: scroll), "The result body should start in the viewport")
        }
        try await verifyFinalResultAndFooter(host, entry: entry, scroll: scroll, document: document)
    }

    private func verifyFinalResultAndFooter(_ host: PaneHost, entry: Bool, scroll: NSScrollView, document: NSView) async throws {
        var markerVisible = entry
        var markerOffset: CGFloat = 0
        var markerMaximum: CGFloat = 0
        await host.page.settle {
            let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, maximum - 180)))
            scroll.reflectScrolledClipView(scroll.contentView)
            markerOffset = scroll.contentView.bounds.origin.y
            markerMaximum = maximum
            markerVisible = entry || isVisible(host, "COMPACT_EVENTS_FINAL_RESULT_MARKER", in: scroll)
            return markerVisible
        }
        if !entry {
            #expect(markerVisible, "The unique final result marker must be visible at its own scroll position")
            #expect(markerOffset < markerMaximum - 2, "Marker observation must be separate from the footer observation")
        }

        var metricsVisible = false
        await host.page.settle {
            let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: maximum))
            scroll.reflectScrolledClipView(scroll.contentView)
            metricsVisible = ["Duration", "Input tokens", "Output tokens", "Cost", "Reported by current agent run"]
                .allSatisfy { isVisible(host, $0, in: scroll) }
            return metricsVisible
        }
        #expect(metricsVisible, "Each recorded metric and its provenance must be visible in the main scroll")

        var footerVisible = false
        await host.page.settle {
            let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: maximum))
            scroll.reflectScrolledClipView(scroll.contentView)
            footerVisible = isVisible(host, "Public normalized events", in: scroll)
            return footerVisible
        }
        #expect(footerVisible, "The Public Events footer must be reachable in the pane's main scroll view")
        let finalMaximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
        #expect(abs(scroll.contentView.bounds.origin.y - finalMaximum) <= 2, "The outer Events scroll reaches its final offset")
    }

    @Test func givenOnlyAgentTurns_whenTheUsageGroupIsOpen_thenNoInlineProvenanceIsShown() async throws {
        let host = await mount(SummaryEntryPaneMocks.turnsOnly(), store: store())
        defer { host.close() }

        let scroll = try #require(host.paneScrollViews().first)
        #expect(host.headerValue("Reported result and usage") == "Expanded")
        #expect(!has(host, "Reported by current agent run"))
        #expect(!has(host, "Duration"))
        #expect(!has(host, "Input tokens"))
        #expect(!has(host, "Output tokens"))
        #expect(!has(host, "Cost"))
        #expect(isVisible(host, "Reported result and usage unavailable.", in: scroll))
    }

    @Test func givenTranscriptSummaryWithoutRecordedMeasurements_whenTheUsageGroupIsOpen_thenUsageUnavailableIsShown() async throws {
        let host = await mount(SummaryEntryPaneMocks.unavailable(entry: true), store: store())
        defer { host.close() }

        let scroll = try #require(host.paneScrollViews().first)
        #expect(host.headerValue("Reported usage") == "Expanded")
        #expect(isVisible(host, "Reported usage unavailable.", in: scroll))
        #expect(!has(host, "Reported result and usage unavailable."))
        #expect(!has(host, "Reported by current agent run"))
        #expect(!has(host, "Duration"))
        #expect(!has(host, "Input tokens"))
        #expect(!has(host, "Output tokens"))
        #expect(!has(host, "Cost"))
    }

    /// The preview mock is not observable, so a switch is a fresh mount over the same store, as a conversation reopened
    /// with the entry would be.
    @Test func givenAnExpandedUsageGroup_whenTheEntryAppears_thenTheGroupStaysExpandedUnderTheNewHeading() async {
        // given
        let store = store()
        let before = await mount(SummaryEntryPaneMocks.done(entry: false), store: store)
        #expect(before.headerValue("Reported result and usage") == "Expanded")
        before.close()

        // when
        let host = await mount(SummaryEntryPaneMocks.done(entry: true), store: store)
        defer { host.close() }

        // then
        #expect(host.headerValue("Reported usage") == "Expanded")
        #expect(host.header("Reported result and usage") == nil)
        #expect(store.expandedGroups(for: Self.conversation).contains(.usage))
    }

    @Test func givenACollapsedUsageGroup_whenTheEntryShows_thenItStaysCollapsedUnderTheNewHeading() async {
        // given
        let store = TaskPaneStateStore()
        store.setOpenChoice(.open, for: Self.conversation)
        store.setSelectedTab(.events, for: Self.conversation)
        let before = await mount(SummaryEntryPaneMocks.done(entry: false), store: store)
        #expect(before.headerValue("Reported result and usage") == "Collapsed")
        before.close()

        // when
        let host = await mount(SummaryEntryPaneMocks.done(entry: true), store: store)
        defer { host.close() }

        // then
        #expect(host.headerValue("Reported usage") == "Collapsed")
        #expect(!store.expandedGroups(for: Self.conversation).contains(.usage))
    }
}
