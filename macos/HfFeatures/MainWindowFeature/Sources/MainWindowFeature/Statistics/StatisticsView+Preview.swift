#if DEBUG
    import Observation
    import SwiftUI

    // MARK: - StatisticsPreviewMock

    @Observable @MainActor
    private final class StatisticsPreviewMock: StatisticsViewModel {
        var presentation: StatisticsPresentation

        init() {
            var value = StatisticsPresentation()
            value.state = .ready
            var bars: [StatisticsBar] = []
            for index in 0 ..< 30 {
                let workflow = Double(index % 8 + 1) / 12.0
                let task = Double(index % 3) / 20.0
                let workflowText = String(format: "%.1f h", workflow * 10), taskText = String(format: "%.1f h", task * 10)
                let total = String(format: "%.1f h", (workflow + task) * 10)
                let label = index.isMultiple(of: 7) ? "Oct \(index + 1)" : ""
                bars.append(StatisticsBar(
                    id: String(index),
                    label: label,
                    accessibilityLabel: "Wed, Oct \(index + 1): total \(total), workflows \(workflowText), tasks \(taskText)",
                    workflowFraction: workflow,
                    taskFraction: task,
                    hoverDate: "Wed, Oct \(index + 1)",
                    hoverTotal: total,
                    hoverWorkflow: workflowText,
                    hoverTasks: taskText
                ))
            }
            value.chart = StatisticsChart(
                title: "Total time", total: "85 h 32 min", caption: "Elapsed run time per workflow run plus task time",
                workflowTotal: "74 h 12 min", taskTotal: "11 h 20 min", topAxis: "10 h", middleAxis: "5 h", bottomAxis: "0", bars: bars
            )
            value.rows = [StatisticsRow(
                id: "workflow",
                title: "Implement and review",
                subtitle: "96 runs · 24 min avg",
                value: "38 h 12 min",
                secondaryValue: "2.6 M tokens",
                fraction: 1,
                isExpanded: true,
                children: [StatisticsChildRow(
                    id: "run",
                    title: "Oct 25, 10:00",
                    subtitle: "Done · 5 nodes",
                    value: "42 min",
                    secondaryValue: "20 k tokens",
                    fraction: 1
                )],
                childrenTitle: "Workflow runs, longest first",
                childrenFooter: "Showing 1 of 96 runs",
                canShowNodes: true
            )]
            value.coverage = ["Retained history only · Usage coverage varies by harness"]
            self.presentation = value
        }

        func didAppear() {}
        func didDisappear() {}
        func selectRange(_ value: StatisticsRange) { presentation.range = value }
        func selectMeasure(_ value: StatisticsMeasure) { presentation.measure = value }
        func selectList(_ value: StatisticsList) { presentation.list = value }
        func selectRepository(_ id: String?) { presentation.repository = id }
        func selectHarness(_ id: String?) { presentation.harness = id }
        func selectRequestedModel(_ id: String?) { presentation.requestedModel = id }
        func toggleRow(_ id: String) {
            guard let index = presentation.rows.firstIndex(where: { $0.id == id }) else { return }
            presentation.rows[index].isExpanded.toggle()
        }

        func showNodes(for id: String) {
            presentation.nodes = StatisticsNodePage(
                workflowID: id,
                title: "Implement and review",
                subtitle: "96 runs",
                wallTime: "38 h 12 min",
                executionTime: "42 h",
                usage: "2.6 M tokens",
                rows: [],
                footer: "Share of summed execution time"
            )
        }

        func showOverview() { presentation.nodes = nil }
        func retry() {}
    }

    #Preview("Statistics - light") {
        StatisticsView(StatisticsPreviewMock()).frame(width: 1000, height: 800).preferredColorScheme(.light)
    }

    #Preview("Statistics - dark") {
        StatisticsView(StatisticsPreviewMock()).frame(width: 1000, height: 800).preferredColorScheme(.dark)
    }
#endif
