import Foundation
import MonitorCore

// MARK: - StatisticsProjection

/// Immutable presentation derivation, invoked only by the background worker.
enum StatisticsProjection {
    static let unknownModel = "unknown:requested-model"
    static let unknownHarness = "unknown:requested-harness"
    static let unknownRepository = "unknown:repository"
    static func requestedModelID(_ fact: StatisticsFact)
        -> String { identity(fact.text("requested_model"), namespace: "model", unknown: unknownModel) }
    static func requestedHarnessID(_ fact: StatisticsFact) -> String { identity(
        fact.text("requested_harness"),
        namespace: "harness",
        unknown: unknownHarness
    ) }
    static func repositoryID(_ fact: StatisticsFact)
        -> String { identity(repositoryPath(fact), namespace: "repository", unknown: unknownRepository) }
    static func repositoryPath(_ fact: StatisticsFact) -> String? {
        guard let path = fact.text("repo_path"), !path.isEmpty else { return nil }
        return path
    }

    static func identity(_ value: String?, namespace: String, unknown: String) -> String {
        value.map { namespace + ":" + JSONValue.string($0).rendered() } ?? unknown
    }

    static func filterLabel(_ identity: String?, options: [StatisticsOption], namespace: String) -> String? {
        guard let identity else { return nil }
        if let option = options.first(where: { $0.id == identity }) { return option.label }
        if [unknownRepository, unknownHarness, unknownModel].contains(identity) { return "Unknown" }
        let prefix = namespace + ":"
        guard identity.hasPrefix(prefix), let encoded = String(identity.dropFirst(prefix.count)).data(using: .utf8),
              let label = JSONValue.parse(encoded)?.stringValue else { return "Unavailable selection" }
        return label
    }

    static func key(_ values: [String?]) -> String { JSONValue.array(values.map { $0.map(JSONValue.string) ?? .null }).rendered() }
    static func bounds(range: StatisticsRange, now: Date, calendar: Calendar) -> (since: String, before: String) {
        let today = calendar.startOfDay(for: now)
        let since = calendar.date(byAdding: .day, value: 1 - range.rawValue, to: today) ?? today
        let before = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        let formatter = ISO8601DateFormatter()
        return (formatter.string(from: since), formatter.string(from: before))
    }

    static func identityOptions(_ facts: [StatisticsFact], field: String) -> [StatisticsOption] {
        var labels: [String: String] = [:]
        for fact in facts {
            let identity = field == "repo_path" ? repositoryID(fact)
                : field == "requested_model" ? requestedModelID(fact) : requestedHarnessID(fact)
            labels[identity] = (field == "repo_path" ? repositoryPath(fact) : fact.text(field)) ?? "Unknown"
        }
        return labels.keys.sorted().map { .init(id: $0, label: labels[$0] ?? "Unknown") }
    }

    static func derive(snapshot: StatisticsSnapshot, selection: StatisticsSelection, now: Date, calendar: Calendar) -> StatisticsPresentation {
        var result = StatisticsPresentation()
        result.state = snapshot.facts.isEmpty ? .empty("No finished work in this retained history.") : .ready
        result.range = selection.range; result.measure = selection.measure; result.list = selection.list
        result.repository = selection.repository; result.harness = selection.harness; result.requestedModel = selection.requestedModel
        result.repositoryOptions = identityOptions(
            snapshot.facts.filter { $0.kind == "workflow" || $0.text("root_workflow_run_id") == nil },
            field: "repo_path"
        )
        let executions = snapshot.facts.filter { $0.kind == "execution" }
        result.harnessOptions = identityOptions(executions, field: "requested_harness")
        result.modelOptions = identityOptions(executions, field: "requested_model")
        result.repositoryLabel = filterLabel(selection.repository, options: result.repositoryOptions, namespace: "repository")
        result.harnessLabel = filterLabel(selection.harness, options: result.harnessOptions, namespace: "harness")
        result.modelLabel = filterLabel(selection.requestedModel, options: result.modelOptions, namespace: "model")
        let filtered = repositoryCohort(snapshot.facts, repository: selection.repository)
        let matching = filtered.filter { fact in
            fact.kind == "execution" && (selection.harness == nil || requestedHarnessID(fact) == selection.harness)
                && (selection.requestedModel == nil || requestedModelID(fact) == selection.requestedModel)
        }
        let queryCalendar = snapshot.calendar ?? calendar
        let anchor = snapshot.anchorDate ?? now
        let ranking = ranking(facts: filtered, matching: matching, selection: selection, calendar: queryCalendar)
        result.rows = ranking.rows
        result.chart = chart(facts: filtered, executions: matching, selection: selection, now: anchor, calendar: queryCalendar)
        let filteredTime = selection.harness != nil || selection.requestedModel != nil
        let metric = selection
            .measure == .usage ? "comparable tokens" : (filteredTime || selection.list != .workflows ? "execution time" : "wall time")
        result.listTitle = "\(selection.list.rawValue) by \(metric)"
        result.primaryColumn = selection.measure == .usage ? "Usage" : filteredTime || selection.list != .workflows ? "Execution time" : "Total time"
        result.secondaryColumn = selection.measure == .time ? "Usage" : filteredTime || selection.list != .workflows ? "Execution time" : "Total time"
        result.listFooter = "Usage is the known qualified subtotal; missing usage is excluded. Parallel execution sums can exceed workflow wall time."
        result.coverage = coverage(snapshot, selected: matching, label: "Chart")
        result.coverage.append(accountingCoverage(rankingExecutions(matching, list: selection.list), label: selection.list.rawValue + " ranking"))
        if let id = selection.nodes, let roots = ranking.groups[id], selection.list == .workflows {
            let members = workflowMembers(roots, matching: matching)
            result.nodes = nodePage(id: id, roots: roots, executions: members, selection: selection, calendar: queryCalendar)
            result.coverage = coverage(snapshot, selected: members, label: "Selected workflow")
        }
        return result
    }

    static func rankingExecutions(_ facts: [StatisticsFact], list: StatisticsList) -> [StatisticsFact] {
        switch list {
        case .tasks: facts.filter { $0.text("root_workflow_run_id") == nil }
        case .workflows: facts.filter { $0.text("root_workflow_run_id") != nil }
        case .harnesses: facts
        }
    }

    static func repositoryCohort(_ facts: [StatisticsFact], repository: String?) -> [StatisticsFact] {
        guard let repository else { return facts }
        let roots = facts.filter { $0.kind == "workflow" && repositoryID($0) == repository }
        let selectedRoots = Set(roots.compactMap { $0.text("root_workflow_run_id") })
        return facts.filter { fact in
            if fact.kind == "workflow" { return repositoryID(fact) == repository }
            if let root = fact.text("root_workflow_run_id") { return selectedRoots.contains(root) }
            return repositoryID(fact) == repository
        }
    }

    static func workflowMembers(_ roots: [StatisticsFact], matching: [StatisticsFact]) -> [StatisticsFact] {
        let rootIDs = Set(roots.compactMap { $0.text("root_workflow_run_id") })
        return matching.filter { $0.text("root_workflow_run_id").map(rootIDs.contains) == true }
    }

    static func workflowKey(_ fact: StatisticsFact) -> String {
        guard let identity = fact.text("workflow_id"), !identity.isEmpty else { return key(["unknown-workflow", fact.id]) }
        return key(["workflow", identity])
    }

    static func taskKey(_ fact: StatisticsFact) -> String {
        key(["task", fact.text("repo_path"), fact.text("chain_root_task_id") ?? fact.text("task_id") ?? fact.id])
    }
}
