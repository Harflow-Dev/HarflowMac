import Foundation
import MonitorCore

// MARK: - Statistics task summary

/// Standalone task chains: Tasks run and Success rate.
///
/// A chain is a root execution plus its continuations and resumes, linked through `continuation_of_task_id`
/// and `parent_task_id`. Only chains whose first run is present and started in the selected period count.
extension StatisticsProjection {
    static let chainDepthLimit = 1000

    enum ChainOutcome: Equatable { case completed, failed, cancelled }

    /// A candidate that cannot be counted, in the order the coverage categories apply.
    enum ChainExclusion: Equatable { case invalidRecord, unidentifiedFirstRun }

    struct StandaloneChains {
        /// Counted chains: root task id mapped to its member facts.
        var chains: [String: [StatisticsFact]] = [:]
        var excluded: [(fact: StatisticsFact, reason: ChainExclusion)] = []
        /// Chain nodes visited while resolving; linear in the number of facts (asserted by tests).
        var resolutionSteps = 0
    }

    /// Where a task's chain ends: `root` is nil when the first run is absent, `depth` counts hops from that top.
    private enum Resolution { case top(root: String?, depth: Int), invalid }

    private static func link(_ fact: StatisticsFact, _ key: String) -> String? {
        guard let value = fact.text(key), !value.isEmpty else { return nil }
        return value
    }

    /// The engine's rule (statistics.py): continuation, else resume, else initial.
    private static func derivedKind(_ fact: StatisticsFact) -> String {
        link(fact, "continuation_of_task_id") != nil ? "continuation" : link(fact, "parent_task_id") != nil ? "resume" : "initial"
    }

    private static func predecessor(_ fact: StatisticsFact) -> String? {
        link(fact, "continuation_of_task_id") ?? link(fact, "parent_task_id")
    }

    private static func isValidCandidate(_ fact: StatisticsFact) -> Bool {
        guard link(fact, "task_id") != nil,
              ["completed", "failed", "cancelled", "timed_out"].contains(fact.text("status") ?? ""),
              fact.number("started_at") != nil, fact.number("finished_at") != nil,
              fact.text("execution_kind") == derivedKind(fact) else { return false }
        return true
    }

    private struct DisjointSet {
        var parent: [String: String] = [:]

        mutating func find(_ id: String) -> String {
            var root = id
            while let next = parent[root], next != root { root = next }
            var current = id
            while let next = parent[current], next != root { parent[current] = root; current = next }
            return root
        }

        mutating func union(_ lhs: String, _ rhs: String) {
            parent[lhs] = parent[lhs] ?? lhs
            parent[rhs] = parent[rhs] ?? rhs
            parent[find(lhs)] = find(rhs)
        }
    }

    /// Splits candidates into valid facts by task id and invalid records.
    private static func partition(_ candidates: [StatisticsFact]) -> (valid: [String: StatisticsFact], invalid: [StatisticsFact]) {
        var byTask: [String: Int] = [:]
        for fact in candidates where isValidCandidate(fact) { byTask[link(fact, "task_id") ?? "", default: 0] += 1 }
        var valid: [String: StatisticsFact] = [:]
        var invalid: [StatisticsFact] = []
        for fact in candidates {
            // A repeated task id cannot be attributed to one execution.
            if isValidCandidate(fact), let task = link(fact, "task_id"), byTask[task] == 1 { valid[task] = fact } else { invalid.append(fact) }
        }
        return (valid, invalid)
    }

    /// Builds the chains of standalone executions from the full snapshot, before any filter.
    static func standaloneChains(_ facts: [StatisticsFact]) -> StandaloneChains {
        let candidates = facts.filter { $0.kind == "execution" && $0.text("root_workflow_run_id") == nil }
        var result = StandaloneChains()
        let (valid, invalid) = partition(candidates)
        result.excluded = invalid.map { ($0, .invalidRecord) }
        // Union over links whose predecessor is present, so one invalid resolution invalidates its whole chain.
        var components = DisjointSet()
        for (task, fact) in valid {
            components.parent[task] = components.parent[task] ?? task
            if let pred = predecessor(fact), valid[pred] != nil { components.union(task, pred) }
        }
        var cache: [String: Resolution] = [:]
        for task in valid.keys { resolve(task, valid: valid, cache: &cache, steps: &result.resolutionSteps) }
        var invalidComponents: Set<String> = []
        for (task, resolution) in cache { if case .invalid = resolution { invalidComponents.insert(components.find(task)) } }
        for (task, fact) in valid {
            if invalidComponents.contains(components.find(task)) { result.excluded.append((fact, .invalidRecord)); continue }
            if case .top(let root?, _)? = cache[task] {
                result.chains[root, default: []].append(fact)
            } else {
                result.excluded.append((fact, .unidentifiedFirstRun))
            }
        }
        return result
    }

    /// Resolves one task and every unresolved ancestor once, iteratively, so total work stays linear.
    private static func resolve(
        _ start: String, valid: [String: StatisticsFact], cache: inout [String: Resolution], steps: inout Int
    ) {
        guard cache[start] == nil else { return }
        var path: [String] = []
        var onPath: Set<String> = []
        var current = start
        var base = Resolution.invalid
        while true {
            if let known = cache[current] { base = known; break }
            if onPath.contains(current) { base = .invalid; break }
            steps += 1
            onPath.insert(current); path.append(current)
            guard let fact = valid[current] else { break }
            guard let pred = predecessor(fact) else {
                base = .top(root: current, depth: -1); break
            }
            guard valid[pred] != nil else { base = .top(root: nil, depth: -1); break }
            current = pred
        }
        for node in path.reversed() {
            switch base {
            case .invalid: base = .invalid
            case .top(let root, let depth): base = depth + 1 > chainDepthLimit ? .invalid : .top(root: root, depth: depth + 1)
            }
            cache[node] = base
        }
    }

    /// The member with the greatest `finished_at`, then `started_at`, then fact id.
    static func chainOutcome(_ members: [StatisticsFact]) -> ChainOutcome? {
        let latest = members.max { lhs, rhs in
            let (lhsEnd, rhsEnd) = (lhs.number("finished_at") ?? 0, rhs.number("finished_at") ?? 0)
            if lhsEnd != rhsEnd { return lhsEnd < rhsEnd }
            let (lhsStart, rhsStart) = (lhs.number("started_at") ?? 0, rhs.number("started_at") ?? 0)
            if lhsStart != rhsStart { return lhsStart < rhsStart }
            return lhs.id < rhs.id
        }
        switch latest?.text("status") {
        case "completed": return .completed
        case "failed", "timed_out": return .failed
        case "cancelled": return .cancelled
        default: return nil
        }
    }

    /// Whole percent, half-up, never 100 while a chain did not complete and never 0 while one did.
    static func successPercent(completed: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        var percent = Int((Double(completed) * 100 / Double(total)).rounded(.toNearestOrAwayFromZero))
        if completed < total { percent = min(percent, 99) }
        if completed > 0 { percent = max(percent, 1) }
        return percent
    }

    static func taskSummary(
        snapshot: StatisticsSnapshot, selection: StatisticsSelection, calendar: Calendar, anchor: Date
    ) -> StatisticsTaskSummary {
        let today = calendar.startOfDay(for: anchor)
        let since = (calendar.date(byAdding: .day, value: 1 - selection.range.rawValue, to: today) ?? today).timeIntervalSince1970
        let before = (calendar.date(byAdding: .day, value: 1, to: today) ?? anchor).timeIntervalSince1970
        func matches(_ fact: StatisticsFact) -> Bool {
            (selection.repository == nil || repositoryID(fact) == selection.repository)
                && (selection.harness == nil || requestedHarnessID(fact) == selection.harness)
                && (selection.requestedModel == nil || requestedModelID(fact) == selection.requestedModel)
        }
        let built = standaloneChains(snapshot.facts)
        var completed = 0, failed = 0, cancelled = 0
        for members in built.chains.values {
            guard let root = members.first(where: { predecessor($0) == nil }), matches(root),
                  let started = root.number("started_at"), started >= since, started < before,
                  let outcome = chainOutcome(members) else { continue }
            switch outcome {
            case .completed: completed += 1
            case .failed: failed += 1
            case .cancelled: cancelled += 1
            }
        }
        let total = completed + failed + cancelled
        var summary = StatisticsTaskSummary()
        summary.tasksRun = String(total)
        summary.tasksDetail = "Last \(selection.range.rawValue) days"
        if total > 0 {
            summary.successRate = "\(successPercent(completed: completed, total: total))%"
            summary.successDetail = "\(failed) failed" + (cancelled > 0 ? " · \(cancelled) cancelled" : "")
            summary.successCaption = "As of latest finished execution"
            summary.coverage.append("Agent-started tasks count as top-level tasks.")
        }
        summary.coverage.append(
            "Counts tasks with a finished execution and an identifiable first run in this period. "
                + "Tasks still running without a finished execution aren't shown."
        )
        let unidentified = built.excluded.filter { $0.reason == .unidentifiedFirstRun && matches($0.fact) }.count
        let invalid = built.excluded.filter { $0.reason == .invalidRecord && matches($0.fact) }.count
        if unidentified > 0 {
            summary.coverage.append(unidentified == 1
                ? "1 later execution isn't counted because its first run couldn't be identified in the available history."
                : "\(unidentified) later executions aren't counted because their first run couldn't be identified in the available history.")
        }
        if invalid > 0 {
            summary.coverage.append(invalid == 1
                ? "1 execution record couldn't be read and isn't counted."
                : "\(invalid) execution records couldn't be read and aren't counted.")
        }
        return summary
    }
}
