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

    static func done(entry: Bool) -> TaskDetailViewModelMock {
        let mock = PaneMocks.done(exit: 0)
        var raw = mock.task!.raw
        raw["duration_seconds"] = .number(1260)
        raw["num_turns"] = .number(7)
        raw["usage"] = .object(["input_tokens": .number(12_000), "output_tokens": .number(3_400)])
        raw["summary"] = .string(summary)
        let task = TaskInfo(.object(raw))!
        mock.task = task
        mock.summaryModel = SummaryPaneModel.build(task: task, summary: summary, events: [], eventsAvailability: .available)
        mock.summaryEntryShown = entry
        if entry {
            let model = mock.timelineModel
            let markdown = StreamingMarkdownState().updating(text: summary, isStreaming: false)
            let row = ActivityRow.summary(SummaryEntry(
                id: SummaryEntry.rowID(taskID: PaneMocks.taskID), taskID: PaneMocks.taskID, text: summary, markdown: markdown))
            mock.timelineModel = TimelinePaneModel(
                stepCountText: model.stepCountText, rows: model.rows, activityRows: model.activityRows + [row], start: model.start,
                emptyText: nil, subTaskStrip: nil, isLoading: false, liveStep: nil,
                updateToken: ActivityUpdateToken(rows: model.rows, liveStep: nil), history: EventHistoryState(hasMore: true))
        }
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

    private func mount(_ mock: TaskDetailViewModelMock, store: TaskPaneStateStore) async -> PaneHost {
        let host = PaneHost(PaneMocks.standalone(mock, store: store), size: CGSize(width: 1280, height: 900))
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
        #expect(has(host, "Tokens"))
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
