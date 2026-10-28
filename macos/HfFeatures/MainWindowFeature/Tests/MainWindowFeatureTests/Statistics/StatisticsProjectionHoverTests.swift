import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

struct StatisticsProjectionHoverTests: StatisticsFixtures {

    // MARK: - Chart hover

    private var hoverNow: Date { ISO8601DateFormatter().date(from: "2026-10-28T12:00:00-07:00")! }

    private func hoverDate(daysBeforeNow offset: Int) -> String {
        let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: hoverNow))!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return formatter.string(from: day)
    }

    private func hoverBars(
        _ facts: [StatisticsFact], selection: StatisticsSelection = StatisticsSelection(range: .seven)
    ) -> [StatisticsBar] {
        StatisticsProjection.derive(snapshot: snapshot(facts), selection: selection, now: hoverNow, calendar: calendar).chart.bars
    }

    private func sharingContribution(of source: StatisticsFact, id: String) -> StatisticsFact {
        var raw = source.raw
        raw["id"] = .string(id)
        raw.removeValue(forKey: "root_workflow_run_id")
        raw["chain_root_task_id"] = .string("task-root")
        return fact(raw)
    }

    @Test func givenTimeDayWithWorkflowAndTask_whenChartBuilt_thenBarCarriesHoverStringsWithoutNote() throws {
        // given
        let cohort = hoverNow.timeIntervalSince1970
        let root = workflow("root", cohort: cohort, wall: 300)
        let task = execution("task", cohort: cohort, duration: 60)

        // when
        let bar = try #require(hoverBars([root, task]).last)

        // then
        #expect(bar.hoverDate == hoverDate(daysBeforeNow: 0))
        #expect(bar.hoverWorkflow == "5.0 min")
        #expect(bar.hoverTasks == "1.0 min")
        #expect(bar.hoverTotal == "6.0 min")
        #expect(bar.hasFinishedWork)
        #expect(bar.hoverNote == nil)
    }

    @Test func givenTimeDayWithAndWithoutFinishedWork_whenChartBuilt_thenAccessibilityLabelNamesTotalAndSeries() throws {
        // given
        let cohort = hoverNow.timeIntervalSince1970
        let bars = hoverBars([workflow("root", cohort: cohort, wall: 300), execution("task", cohort: cohort, duration: 60)])

        // when
        let populated = try #require(bars.last)
        let empty = try #require(bars.first)

        // then
        #expect(populated.accessibilityLabel == "\(hoverDate(daysBeforeNow: 0)): total 6.0 min, workflows 5.0 min, tasks 1.0 min")
        #expect(empty.accessibilityLabel == "\(hoverDate(daysBeforeNow: 6)): no finished work")
    }

    @Test func givenUsageDay_whenChartBuilt_thenTotalCombinesBothSeriesAndNoteIsSet() throws {
        // given
        let cohort = hoverNow.timeIntervalSince1970
        let inWorkflow = execution("flow-node", cohort: cohort, root: "root", usage: 100)
        let standalone = execution("task", cohort: cohort, usage: 50)

        // when
        let bar = try #require(hoverBars([inWorkflow, standalone], selection: StatisticsSelection(range: .seven, measure: .usage)).last)

        // then
        #expect(bar.hoverDate == hoverDate(daysBeforeNow: 0))
        #expect(bar.hoverWorkflow == "100 tokens")
        #expect(bar.hoverTasks == "50 tokens")
        #expect(bar.hoverTotal == "150 tokens")
        #expect(bar.hasFinishedWork)
        #expect(bar.hoverNote == "Known qualified usage only")
        #expect(bar.accessibilityLabel == "\(hoverDate(daysBeforeNow: 0)): total 150 tokens, workflows 100 tokens, "
            + "tasks 50 tokens, known qualified usage only")
    }

    @Test func givenContributionSharedByBothSeries_whenUsageChartBuilt_thenDayTotalCountsItOnce() throws {
        // given
        let cohort = hoverNow.timeIntervalSince1970
        let inWorkflow = execution("flow-node", cohort: cohort, root: "root", usage: 100)
        let standalone = sharingContribution(of: inWorkflow, id: "task-copy")

        // when
        let bar = try #require(hoverBars([inWorkflow, standalone], selection: StatisticsSelection(range: .seven, measure: .usage)).last)

        // then
        #expect(bar.hoverWorkflow == "100 tokens")
        #expect(bar.hoverTasks == "100 tokens")
        #expect(bar.hoverTotal == "100 tokens")
    }

    @Test(arguments: [StatisticsMeasure.time, StatisticsMeasure.usage])
    func givenDayWithoutFacts_whenChartBuilt_thenBarShowsZeroTotalAndNoFinishedWork(measure: StatisticsMeasure) throws {
        // given
        let cohort = hoverNow.timeIntervalSince1970
        let facts = [execution("task", cohort: cohort, duration: 60, usage: 10)]

        // when
        let bar = try #require(hoverBars(facts, selection: StatisticsSelection(range: .seven, measure: measure)).first)

        // then
        #expect(!bar.hasFinishedWork)
        #expect(bar.hoverTotal == (measure == .usage ? "0 tokens" : "0 s"))
        #expect(bar.hoverDate == hoverDate(daysBeforeNow: 6))
        #expect(bar.accessibilityLabel == "\(hoverDate(daysBeforeNow: 6)): no finished work")
    }

    @Test func givenUsageDayWithFactsButNoQualifiedUsageInEitherSeries_whenChartBuilt_thenTotalAndSeriesAreUnavailable() throws {
        // given
        let cohort = hoverNow.timeIntervalSince1970
        let inWorkflow = execution("flow-node", cohort: cohort, duration: 60, root: "root")
        let task = execution("task", cohort: cohort, duration: 60)

        // when
        let bar = try #require(hoverBars([inWorkflow, task], selection: StatisticsSelection(range: .seven, measure: .usage)).last)

        // then
        #expect(bar.hasFinishedWork)
        #expect(bar.hoverTotal == "Unavailable")
        #expect(bar.hoverWorkflow == "Unavailable")
        #expect(bar.hoverTasks == "Unavailable")
    }

    @Test func givenUsageDayWithWorkflowFactsOnly_whenChartBuilt_thenTasksReadZeroAndLabelMatches() throws {
        // given
        let inWorkflow = execution("flow-node", cohort: hoverNow.timeIntervalSince1970, root: "root", usage: 100)

        // when
        let result = StatisticsProjection.derive(
            snapshot: snapshot([inWorkflow]), selection: StatisticsSelection(range: .seven, measure: .usage),
            now: hoverNow, calendar: calendar
        )
        let bar = try #require(result.chart.bars.last)

        // then
        #expect(bar.hoverWorkflow == "100 tokens")
        #expect(bar.hoverTasks == "0 tokens")
        #expect(bar.hoverTotal == "100 tokens")
        #expect(bar.accessibilityLabel == "\(hoverDate(daysBeforeNow: 0)): total 100 tokens, workflows 100 tokens, "
            + "tasks 0 tokens, known qualified usage only")
        #expect(result.chart.taskTotal == "Unavailable")
    }

    @Test func givenUsageDayWithOnlyQualifiedZeroUsage_whenChartBuilt_thenTotalIsZeroNotUnavailable() throws {
        // given
        let cohort = hoverNow.timeIntervalSince1970
        let inWorkflow = execution("flow-node", cohort: cohort, root: "root", usage: 0)
        let task = execution("task", cohort: cohort, usage: 0)

        // when
        let bar = try #require(hoverBars([inWorkflow, task], selection: StatisticsSelection(range: .seven, measure: .usage)).last)

        // then
        #expect(bar.hoverTotal == "0 tokens")
        #expect(bar.hoverWorkflow == "0 tokens")
        #expect(bar.hoverTasks == "0 tokens")
    }

    @Test func givenTimeDayWhoseSeriesSumOverflows_whenChartBuilt_thenTotalIsUnavailable() throws {
        // given
        let cohort = hoverNow.timeIntervalSince1970
        let root = workflow("root", cohort: cohort, wall: 1.7e308)
        let task = execution("task", cohort: cohort, duration: 1.7e308)

        // when
        let bar = try #require(hoverBars([root, task]).last)

        // then
        #expect(bar.hoverWorkflow != "Unavailable")
        #expect(bar.hoverTasks != "Unavailable")
        #expect(bar.hoverTotal == "Unavailable")
    }

    @Test func givenUsageDayWithOneSeriesUnavailable_whenChartBuilt_thenTotalIsKnownSubtotal() throws {
        // given
        let cohort = hoverNow.timeIntervalSince1970
        let known = execution("flow-node", cohort: cohort, root: "root", usage: 100)
        let missing = execution("task", cohort: cohort)

        // when
        let bar = try #require(hoverBars([known, missing], selection: StatisticsSelection(range: .seven, measure: .usage)).last)

        // then
        #expect(bar.hoverWorkflow == "100 tokens")
        #expect(bar.hoverTasks == "Unavailable")
        #expect(bar.hoverTotal == "100 tokens")
    }

    @Test func givenTimeDayWithUnavailableTasks_whenChartBuilt_thenTotalIsUnavailable() throws {
        // given
        let cohort = hoverNow.timeIntervalSince1970
        let root = workflow("root", cohort: cohort, wall: 300)
        let owned = execution("task", cohort: cohort, duration: 60, durationAdditive: false)

        // when
        let bar = try #require(hoverBars([root, owned]).last)

        // then
        #expect(bar.hoverWorkflow == "5.0 min")
        #expect(bar.hoverTasks == "Unavailable")
        #expect(bar.hoverTotal == "Unavailable")
        #expect(bar.hasFinishedWork)
    }

    @Test func givenModelFilter_whenTimeChartBuilt_thenDayTotalUsesExecutionTimeInsteadOfWallTime() throws {
        // given
        let cohort = hoverNow.timeIntervalSince1970
        let root = workflow("root", cohort: cohort, wall: 900)
        let child = execution("child", cohort: cohort, duration: 120, root: "root", model: "wanted")
        let task = execution("task", cohort: cohort, duration: 30, model: "wanted")
        let facts = [root, child, task]

        // when
        let unfiltered = try #require(hoverBars(facts).last)
        let filtered = try #require(hoverBars(facts, selection: StatisticsSelection(range: .seven, requestedModel: "model:\"wanted\"")).last)

        // then
        #expect(unfiltered.hoverWorkflow == "15.0 min")
        #expect(unfiltered.hoverTasks == "30 s")
        #expect(unfiltered.hoverTotal == "15.5 min")
        #expect(filtered.hoverWorkflow == "2.0 min")
        #expect(filtered.hoverTasks == "30 s")
        #expect(filtered.hoverTotal == "2.5 min")
    }

    @Test func givenBarsDifferingOnlyInHoverField_whenCompared_thenTheyAreNotEqual() {
        // given
        let base = StatisticsBar(id: "0", label: "", accessibilityLabel: "a", workflowFraction: 0.5, taskFraction: 0.25)
        let variants: [StatisticsBar] = [
            { var bar = base; bar.hoverDate = "Wed, Oct 28"; return bar }(),
            { var bar = base; bar.hoverTotal = "1 s"; return bar }(),
            { var bar = base; bar.hoverWorkflow = "1 s"; return bar }(),
            { var bar = base; bar.hoverTasks = "1 s"; return bar }(),
            { var bar = base; bar.hasFinishedWork = false; return bar }(),
            { var bar = base; bar.hoverNote = "note"; return bar }()
        ]

        // when
        let copy = base

        // then
        #expect(copy == base)
        for variant in variants { #expect(variant != base) }
    }

    @Test(arguments: [StatisticsRange.seven, .thirty, .ninety])
    func givenRange_whenChartBuilt_thenEveryBarHasDistinctOrderedHoverDate(range: StatisticsRange) {
        // given
        let selection = StatisticsSelection(range: range)

        // when
        let bars = hoverBars([], selection: selection)

        // then
        #expect(bars.count == range.rawValue)
        #expect(bars.map(\.id) == (0 ..< range.rawValue).map(String.init))
        #expect(bars.map(\.hoverDate) == (0 ..< range.rawValue).reversed().map { hoverDate(daysBeforeNow: $0) })
        #expect(bars.allSatisfy { !$0.hasFinishedWork })
    }
}
