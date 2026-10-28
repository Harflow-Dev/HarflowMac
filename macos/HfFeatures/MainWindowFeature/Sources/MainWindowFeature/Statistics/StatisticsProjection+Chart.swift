import Foundation
import MonitorCore

// MARK: - Statistics chart

extension StatisticsProjection {
    struct DayBucket {
        var id: String
        var label: String
        var date: String
        var workflow: Double?
        var tasks: Double?
        var weekdayDate: String
        var hasFinishedWork: Bool
        var hasWorkflowFacts = true
        var hasStandaloneFacts = true
        /// Usage total across both series, de-duplicating shared contributions like the chart-level total.
        var usageTotal: Double?
    }

    static func chart(
        facts: [StatisticsFact],
        executions: [StatisticsFact],
        selection: StatisticsSelection,
        now: Date,
        calendar: Calendar
    ) -> StatisticsChart {
        let filteredTime = selection.harness != nil || selection.requestedModel != nil
        let roots = facts.filter { $0.kind == "workflow" }
        let workflowExecutions = executions.filter { $0.text("root_workflow_run_id") != nil }
        let standalone = executions.filter { $0.text("root_workflow_run_id") == nil }
        let workflowFacts = selection.measure == .time && !filteredTime ? roots : workflowExecutions
        let workflow = value(workflowFacts, measure: selection.measure, wall: !filteredTime)
        let tasks = value(standalone, measure: selection.measure, wall: false)
        var chart = StatisticsChart()
        chart.gap = selection.range == .seven ? 16 : selection.range == .thirty ? 4 : 2
        if selection.measure == .usage { chart.disclosure = usageDisclosure(roots: roots, executions: executions) }
        chart.title = selection.measure == .usage ? "Usage" : filteredTime ? "Execution time" : "Total time"
        let total = selection.measure == .usage ? usage(executions) : workflow
            .flatMap { first in tasks.flatMap { (first + $0).isFinite ? first + $0 : nil } }
        chart.total = formatted(total, measure: selection.measure)
        chart.workflowTotal = formatted(workflow, measure: selection.measure); chart.taskTotal = formatted(tasks, measure: selection.measure)
        chart.caption = selection.measure == .usage ? "Known qualified usage subtotal; coverage below"
            : filteredTime ? "Matching execution time only" : "Workflow wall time + standalone execution time"
        let buckets = dayBuckets(workflows: workflowFacts, standalone: standalone, selection: selection, now: now, calendar: calendar)
        let maximum = buckets.map { ($0.workflow ?? 0) + ($0.tasks ?? 0) }.max() ?? 0
        chart.topAxis = formatted(maximum, measure: selection.measure); chart.middleAxis = formatted(maximum / 2, measure: selection.measure)
        chart.bottomAxis = "0"
        chart.bars = buckets.map { bar(for: $0, maximum: maximum, measure: selection.measure) }
        return chart
    }

    static func bar(for bucket: DayBucket, maximum: Double, measure: StatisticsMeasure) -> StatisticsBar {
        let isUsage = measure == .usage
        let total: Double? = if !bucket.hasFinishedWork {
            0
        } else if isUsage {
            bucket.usageTotal
        } else {
            bucket.workflow.flatMap { first in bucket.tasks.flatMap { (first + $0).isFinite ? first + $0 : nil } }
        }
        let totalText = formatted(total, measure: measure)
        // A series with no facts that day is zero; one with facts but no qualified usage stays unavailable.
        let workflowText = formatted(isUsage && !bucket.hasWorkflowFacts ? 0 : bucket.workflow, measure: measure)
        let tasksText = formatted(isUsage && !bucket.hasStandaloneFacts ? 0 : bucket.tasks, measure: measure)
        let label = bucket.hasFinishedWork
            ? "\(bucket.weekdayDate): total \(totalText), workflows \(workflowText), tasks \(tasksText)"
            + (isUsage ? ", known qualified usage only" : "")
            : "\(bucket.weekdayDate): no finished work"
        return .init(
            id: bucket.id,
            label: bucket.label,
            accessibilityLabel: label,
            workflowFraction: fraction(bucket.workflow ?? 0, maximum),
            taskFraction: fraction(bucket.tasks ?? 0, maximum),
            hoverDate: bucket.weekdayDate,
            hoverTotal: totalText,
            hoverWorkflow: workflowText,
            hoverTasks: tasksText,
            hasFinishedWork: bucket.hasFinishedWork,
            hoverNote: isUsage ? "Known qualified usage only" : nil
        )
    }

    static func usageDisclosure(roots: [StatisticsFact], executions: [StatisticsFact]) -> String {
        let covered = executions.filter { $0.comparableTokens != nil }
        let coveredRoots = Set(covered.compactMap { $0.text("root_workflow_run_id") }).count
        let tasks = executions.filter { $0.text("root_workflow_run_id") == nil }
        let coveredTasks = tasks.filter { $0.comparableTokens != nil }.count
        return "Usage covers contributions from \(coveredRoots) of \(roots.count) workflow runs and \(coveredTasks) of \(tasks.count) standalone executions. "
            + "The rest are left out, not counted as zero. Partial execution coverage remains disclosed below."
    }

    static func dayBuckets(
        workflows: [StatisticsFact],
        standalone: [StatisticsFact],
        selection: StatisticsSelection,
        now: Date,
        calendar: Calendar
    ) -> [DayBucket] {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: 1 - selection.range.rawValue, to: today) ?? today
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "MMM d"
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.calendar = calendar; weekdayFormatter.timeZone = calendar.timeZone
        weekdayFormatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        let wall = selection.harness == nil && selection.requestedModel == nil
        let stride = max(1, (selection.range.rawValue - 1) / 4)
        var buckets: [DayBucket] = []
        for offset in 0 ..< selection.range.rawValue {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start),
                  let end = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
            let inDay: (StatisticsFact) -> Bool = { fact in
                guard let stamp = fact.number("cohort_started_at") else { return false }
                return stamp >= day.timeIntervalSince1970 && stamp < end.timeIntervalSince1970
            }
            let date = formatter.string(from: day)
            let lastOffset = selection.range.rawValue - 1
            let labelled = offset == lastOffset || (offset.isMultiple(of: stride) && lastOffset - offset >= stride)
            let dayWorkflows = workflows.filter(inDay), dayStandalone = standalone.filter(inDay)
            buckets.append(.init(
                id: String(offset),
                label: labelled ? date : "",
                date: date,
                workflow: value(dayWorkflows, measure: selection.measure, wall: wall),
                tasks: value(dayStandalone, measure: selection.measure, wall: false),
                weekdayDate: weekdayFormatter.string(from: day),
                hasFinishedWork: !dayWorkflows.isEmpty || !dayStandalone.isEmpty,
                hasWorkflowFacts: !dayWorkflows.isEmpty,
                hasStandaloneFacts: !dayStandalone.isEmpty,
                usageTotal: selection.measure == .usage ? usage(dayWorkflows + dayStandalone) : nil
            ))
        }
        return buckets
    }
}
