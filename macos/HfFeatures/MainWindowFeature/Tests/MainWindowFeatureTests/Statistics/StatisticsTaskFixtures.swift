import Foundation
@testable import MainWindowFeature
import MonitorCore

/// Chain-aware standalone-task builders for the task summary suites.
extension StatisticsFixtures {
    var day: Double { 86400 }
    var now: Date { Date(timeIntervalSince1970: 1_800_000_000) }
    var start: Double { now.timeIntervalSince1970 - 3600 }

    /// A standalone execution with its own task id, explicit kind and links.
    func task(
        _ id: String, kind: String? = nil, parent: String? = nil, continuation: String? = nil,
        status: String = "completed", started: Double? = nil, duration: Double = 600,
        repository: String = "/repo", harness: String? = nil, model: String? = nil,
        taskID: String?? = nil, root: String? = nil
    ) -> StatisticsFact {
        let begin = started ?? start
        let derived = continuation != nil ? "continuation" : parent != nil ? "resume" : "initial"
        var raw: [String: JSONValue] = [
            "id": .string("execution:" + id), "kind": .string("execution"), "status": .string(status),
            "started_at": .number(begin), "finished_at": .number(begin + duration), "cohort_started_at": .number(begin),
            "duration_additive": .bool(true), "usage_additive": .bool(false), "execution_seconds": .number(duration),
            "repo_path": .string(repository), "execution_kind": .string(kind ?? derived)
        ]
        switch taskID {
        case .none: raw["task_id"] = .string(id)
        case .some(.none): break
        case .some(.some(let value)): raw["task_id"] = .string(value)
        }
        if let parent { raw["parent_task_id"] = .string(parent) }
        if let continuation { raw["continuation_of_task_id"] = .string(continuation) }
        if let root { raw["root_workflow_run_id"] = .string(root) }
        if let harness { raw["requested_harness"] = .string(harness) }
        if let model { raw["requested_model"] = .string(model) }
        return fact(raw)
    }

    func summary(
        _ facts: [StatisticsFact], selection: StatisticsSelection = StatisticsSelection(),
        anchor: Date? = nil, calendar custom: Calendar? = nil
    ) -> StatisticsTaskSummary {
        let source = snapshot(facts, anchorDate: anchor, calendar: custom)
        let result = StatisticsProjection.derive(snapshot: source, selection: selection, now: now, calendar: calendar)
        return result.taskSummary ?? StatisticsTaskSummary(tasksRun: "missing")
    }

    var tokyo: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Asia/Tokyo")!; return value
    }

    func chain(hops: Int) -> [StatisticsFact] {
        var facts = [task("t0")]
        for index in 1 ... hops { facts.append(task("t\(index)", parent: "t\(index - 1)", started: start + Double(index))) }
        return facts
    }
}
