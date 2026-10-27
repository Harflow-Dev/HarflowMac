import Foundation
import MonitorCore

// MARK: - Statistics rankings and drilldown

extension StatisticsProjection {
    static func ranking(facts: [StatisticsFact], matching: [StatisticsFact], selection: StatisticsSelection, calendar: Calendar = .current)
        -> (rows: [StatisticsRow], groups: [String: [StatisticsFact]]) {
        let groups: [String: [StatisticsFact]] = switch selection.list {
        case .workflows: Dictionary(grouping: facts.filter { $0.kind == "workflow" }, by: workflowKey)
        case .tasks: Dictionary(grouping: matching.filter { $0.text("root_workflow_run_id") == nil }, by: taskKey)
        case .harnesses: Dictionary(grouping: matching, by: requestedHarnessID)
        }
        let filteredTime = selection.harness != nil || selection.requestedModel != nil
        var rows: [StatisticsRow] = []
        for (identity, sources) in groups {
            let members = selection.list == .workflows ? workflowMembers(sources, matching: matching) : sources
            if selection.list == .workflows, filteredTime, members.isEmpty { continue }
            rows.append(rankingRow(id: identity, facts: sources, members: members, selection: selection, calendar: calendar))
        }
        return (normalize(rows), groups)
    }

    static func normalize(_ input: [StatisticsRow]) -> [StatisticsRow] {
        var rows = input.sorted { $0.fraction == $1.fraction ? $0.id < $1.id : $0.fraction > $1.fraction }
        let maximum = rows.map(\.fraction).max() ?? 0
        for index in rows.indices {
            rows[index].rank = index + 1
            rows[index].fraction = fraction(rows[index].fraction, maximum)
            let childMaximum = rows[index].children.map(\.fraction).max() ?? 0
            for child in rows[index].children.indices {
                rows[index].children[child].fraction = fraction(rows[index].children[child].fraction, childMaximum)
            }
        }
        return rows
    }

    static func rankingRow(
        id: String,
        facts: [StatisticsFact],
        members: [StatisticsFact],
        selection: StatisticsSelection,
        calendar: Calendar = .current
    ) -> StatisticsRow {
        let wall = selection.list == .workflows && selection.harness == nil && selection.requestedModel == nil
        let durationFacts = wall ? facts : members
        let metricFacts = selection.measure == .time ? durationFacts : members
        let secondaryFacts = selection.measure == .time ? members : durationFacts
        let first = facts[0]
        let title: String = switch selection.list {
        case .workflows: first.text("workflow_name") ?? first.text("workflow_id") ?? "Unknown workflow"
        case .tasks: first.text("title") ?? first.text("task_id") ?? first.id
        case .harnesses: first.text("requested_harness") ?? "Unknown"
        }
        var row = StatisticsRow(
            id: id,
            title: title,
            subtitle: rowSubtitle(facts: facts, members: members, selection: selection, wall: wall),
            value: metricLabel(metricFacts, measure: selection.measure, wall: wall),
            secondaryValue: metricLabel(secondaryFacts, measure: other(selection.measure), wall: wall),
            fraction: value(metricFacts, measure: selection.measure, wall: wall) ?? 0,
            isExpanded: selection.expanded.contains(id),
            glyph: selection.list == .workflows ? "point.3.connected.trianglepath.dotted" : selection.list == .tasks ? "terminal" : nil,
            harnessDot: selection.list == .harnesses
        )
        if selection.list == .harnesses {
            row.childrenTitle = "Requested models"
            let models = Dictionary(grouping: members, by: requestedModelID)
            row.children = models.keys.sorted().map { identity in
                let executions = models[identity] ?? []
                return child(
                    id: identity,
                    title: executions.first?.text("requested_model") ?? "Unknown",
                    facts: executions,
                    selection: selection,
                    wall: false
                )
            }
        } else {
            row.childrenTitle = selection.list == .workflows ? "Runs by selected measure" : "Executions / turns, chronological"
            row.children = previewChildren(facts: facts, members: members, selection: selection, wall: wall, calendar: calendar)
            row.childrenFooter = "Showing \(min(8, facts.count)) of \(facts.count) retained \(selection.list == .workflows ? "runs" : "execution records")."
            row.canShowNodes = selection.list == .workflows
        }
        if selection.list == .harnesses {
            row.children.sort { $0.fraction == $1.fraction ? $0.id < $1.id : $0.fraction > $1.fraction }
            let count = row.children.count
            row.children = Array(row.children.prefix(8))
            row.childrenFooter = "Showing \(min(8, count)) of \(count) requested models by selected measure."
        }
        return row
    }

    static func previewChildren(
        facts: [StatisticsFact],
        members: [StatisticsFact],
        selection: StatisticsSelection,
        wall: Bool,
        calendar: Calendar = .current
    ) -> [StatisticsChildRow] {
        if selection.list == .tasks {
            return facts.sorted { ($0.number("started_at") ?? 0, $0.id) < ($1.number("started_at") ?? 0, $1.id) }
                .prefix(8)
                .map { executionChild($0, executions: [$0], selection: selection, wall: false, calendar: calendar) }
        }
        let byRoot = Dictionary(grouping: members, by: { $0.text("root_workflow_run_id") ?? "" })
        let ranked: [(fact: StatisticsFact, metric: Double)] = facts.map { fact in
            let executions = byRoot[fact.text("root_workflow_run_id") ?? ""] ?? []
            let metricFacts: [StatisticsFact] = if selection.measure == .time, wall { [fact] } else { executions }
            return (fact: fact, metric: value(metricFacts, measure: selection.measure, wall: wall) ?? -1)
        }
        .sorted { $0.metric == $1.metric ? $0.fact.id < $1.fact.id : $0.metric > $1.metric }
        return ranked.prefix(8).map { item in
            let runID = item.fact.text("root_workflow_run_id") ?? ""
            let executions = byRoot[runID] ?? []
            return executionChild(item.fact, executions: executions, selection: selection, wall: wall, calendar: calendar)
        }
    }

    static func rowSubtitle(facts: [StatisticsFact], members: [StatisticsFact], selection: StatisticsSelection, wall: Bool) -> String {
        let durationFacts = wall ? facts : members
        let count = wall ? facts.count : members.filter { $0.raw["duration_additive"]?.boolValue == true }.count
        let average = count > 0 ? value(durationFacts, measure: .time, wall: wall).map { $0 / Double(count) } : nil
        let unit = selection.list == .workflows ? "runs" : "execution records"
        let repos = Set(facts.map { repositoryPath($0) ?? "Unknown repository" }).sorted()
        let context = selection.list == .harnesses ? modelSummary(members) : repos.prefix(2).joined(separator: ", ")
        return "\(facts.count) \(unit) · \(formatted(average, measure: .time)) avg · \(context)"
    }

    static func modelSummary(_ facts: [StatisticsFact]) -> String {
        let models = Set(facts.map { $0.text("requested_model") ?? "Unknown" }).sorted()
        return "Requested: " + models.prefix(4).joined(separator: ", ") + (models.count > 4 ? "…" : "")
    }

    static func child(id: String, title: String, facts: [StatisticsFact], selection: StatisticsSelection, wall: Bool) -> StatisticsChildRow {
        .init(
            id: id,
            title: title,
            subtitle: "\(facts.count) execution records · \(modelSummary(facts))",
            value: metricLabel(facts, measure: selection.measure, wall: wall),
            secondaryValue: metricLabel(facts, measure: other(selection.measure), wall: wall),
            fraction: value(facts, measure: selection.measure, wall: wall) ?? 0
        )
    }

    static func executionChild(
        _ fact: StatisticsFact,
        executions: [StatisticsFact],
        selection: StatisticsSelection,
        wall: Bool,
        calendar: Calendar = .current
    ) -> StatisticsChildRow {
        let durationFacts = wall ? [fact] : executions
        let primary = selection.measure == .time ? durationFacts : executions
        let secondary = selection.measure == .time ? executions : durationFacts
        let context = fact.kind == "workflow"
            ? " · \(Set(executions.compactMap { $0.text("node_id") }).count) nodes · \(modelSummary(executions))" : ""
        return .init(
            id: fact.id,
            title: fact.text("title") ?? fact.id,
            subtitle: metadata(fact, calendar: calendar) + context,
            value: metricLabel(primary, measure: selection.measure, wall: wall),
            secondaryValue: metricLabel(secondary, measure: other(selection.measure), wall: wall),
            fraction: value(primary, measure: selection.measure, wall: wall) ?? 0,
            statusGlyph: statusGlyph(fact), statusLabel: statusLabel(fact), isFailure: fact.isFailureOutcome
        )
    }

    static func metadata(_ fact: StatisticsFact, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        let start = fact.number("started_at").map { formatter.string(from: Date(timeIntervalSince1970: $0)) } ?? "Start unknown"
        let parts = [
            statusLabel(fact),
            start,
            repositoryPath(fact) ?? "Unknown repository",
            fact.text("node_id").map { "Node \($0)" },
            fact.text("execution_kind").map { "Turn \($0)" },
            fact.kind == "execution" ? modelSummary([fact]) : fact.raw["workflow_revision"].map { "Revision \($0.rendered())" },
            fact.text("requested_harness").map { "Harness \($0)" },
            fact.raw["duration_additive"]?.boolValue == false ? "Owner-included native record" : nil,
            fact.text("owner_task_id").map { "Owner \($0) (included)" }
        ]
        return parts.compactMap(\.self).joined(separator: " · ")
    }

    static func nodePage(
        id: String,
        roots: [StatisticsFact],
        executions: [StatisticsFact],
        selection: StatisticsSelection,
        calendar: Calendar = .current
    ) -> StatisticsNodePage {
        let groups = Dictionary(grouping: executions) { fact in
            fact.text("node_id").map { key(["node", $0]) } ?? key(["unattributed-node", fact.id])
        }
        let denominator = value(executions, measure: selection.measure, wall: false)
        let rows = groups.keys.sorted().map { identity in
            nodeRow(id: identity, facts: groups[identity] ?? [], denominator: denominator, selection: selection, calendar: calendar)
        }
        return .init(
            workflowID: id,
            title: roots.first?.text("workflow_name") ?? "Workflow",
            subtitle: "\(roots.count) retained finished runs",
            wallTime: formatted(value(roots, measure: .time, wall: true), measure: .time),
            executionTime: formatted(value(executions, measure: .time, wall: false), measure: .time),
            usage: formatted(usage(executions), measure: .usage),
            rows: normalize(rows),
            footer: "Share denominator: \(formatted(denominator, measure: selection.measure)) summed independent executions. "
                + "Native logical records reference their owner. Unknown per-message accounting is unavailable.",
            runs: String(roots.count), runsBreakdown: statusBreakdown(roots),
            rankingTitle: selection.measure == .usage ? "Nodes by usage" : "Nodes by execution time",
            primaryColumn: selection.measure == .usage ? "Usage" : "Execution time",
            secondaryColumn: selection.measure == .time ? "Usage" : "Execution time"
        )
    }

    static func nodeRow(
        id: String,
        facts: [StatisticsFact],
        denominator: Double?,
        selection: StatisticsSelection,
        calendar: Calendar = .current
    ) -> StatisticsRow {
        let metric = value(facts, measure: selection.measure, wall: false)
        let share = metric.flatMap { amount in denominator.map { total in total > 0 ? String(format: "%.1f%%", amount / total * 100) : "0%" } } ?? "Unavailable"
        let count = facts.filter { $0.raw["duration_additive"]?.boolValue == true }.count
        let mean = count > 0 ? value(facts, measure: .time, wall: false).map { $0 / Double(count) } : nil
        let statuses = Set(facts.map(statusLabel)).sorted().joined(separator: ", ")
        let title = facts.first?.text("node_id") ?? "Unattributed \(facts.first?.text("execution_kind") ?? "execution")"
        return .init(
            id: id,
            title: title,
            subtitle: "\(executionKinds(facts)) · \(harnessSummary(facts)) · \(modelSummary(facts)) · \(facts.count) records · "
                + "\(formatted(mean, measure: .time)) mean · \(statuses) · \(ownerSummary(facts))",
            value: metricLabel(facts, measure: selection.measure, wall: false),
            secondaryValue: metricLabel(facts, measure: other(selection.measure), wall: false),
            fraction: metric ?? 0,
            glyph: executionGlyph(facts), share: share, kindLabel: executionKinds(facts)
        )
    }
}

// MARK: - Evidence labels

extension StatisticsProjection {
    static func ownerSummary(_ facts: [StatisticsFact]) -> String {
        let owners = Set(facts.compactMap { $0.text("owner_task_id") }).sorted()
        if !owners.isEmpty { return "Owner-included: " + owners.prefix(3).joined(separator: ", ") }
        return facts.contains { $0.raw[
            "duration_additive"
        ]?.boolValue == false } ? "Owner-included native evidence" : "Independent execution evidence"
    }

    static func statusGlyph(_ fact: StatisticsFact) -> String? {
        if fact.isFailureOutcome { return "xmark.circle.fill" }
        switch fact.text("status") {
        case "completed": return "checkmark.circle.fill"
        case "cancelled": return "minus.circle.fill"
        default: return nil
        }
    }

    static func statusLabel(_ fact: StatisticsFact) -> String {
        fact.text("status") == "timed_out" ? "failed (timed out)" : fact.text("status") ?? "Status unknown"
    }

    static func statusBreakdown(_ facts: [StatisticsFact]) -> String {
        let statuses = Dictionary(grouping: facts, by: statusLabel)
        return statuses.keys.sorted().map { "\(statuses[$0]?.count ?? 0) \($0)" }.joined(separator: " · ")
    }

    static func executionKinds(_ facts: [StatisticsFact]) -> String {
        Set(facts.map { $0.text("execution_kind") ?? "Unknown kind" }).sorted().joined(separator: ", ")
    }

    static func executionGlyph(_ facts: [StatisticsFact]) -> String? {
        let kinds = Set(facts.compactMap { $0.text("execution_kind") })
        guard kinds.count == 1, let kind = kinds.first else { return nil }
        switch kind {
        case "control": return "arrow.triangle.branch"
        case "native": return "square.stack.3d.up"
        case "initial", "resume", "continuation": return "terminal"
        default: return nil
        }
    }

    static func harnessSummary(_ facts: [StatisticsFact]) -> String {
        Set(facts.map { $0.text("requested_harness") ?? "Unknown harness" }).sorted().prefix(4).joined(separator: ", ")
    }
}
