import Foundation
@testable import MainWindowFeature
import MonitorCore

/// Shared fact, snapshot and calendar builders for the Statistics projection test suites.
protocol StatisticsFixtures {}

extension StatisticsFixtures {
    func fact(_ fields: [String: JSONValue]) -> StatisticsFact { StatisticsFact(raw: fields) }

    func execution(
        _ id: String, cohort: Double, duration: Double = 60, wall: Double? = nil,
        root: String? = nil, repository: String = "/repo", model: String? = nil,
        harness: String? = nil, timeQualification: String? = "qualified_waits", usage: Int? = nil,
        status: String = "completed",
        durationAdditive: Bool = true
    ) -> StatisticsFact {
        var raw: [String: JSONValue] = [
            "id": .string(id), "kind": .string("execution"), "status": .string(status),
            "started_at": .number(cohort), "finished_at": .number(cohort + duration), "cohort_started_at": .number(cohort),
            "execution_seconds": .number(duration), "duration_additive": .bool(durationAdditive), "usage_additive": .bool(usage != nil),
            "repo_path": .string(repository)
        ]
        if let root { raw["root_workflow_run_id"] = .string(root) }
        if root == nil { raw["chain_root_task_id"] = .string("task-root") }
        if let model { raw["requested_model"] = .string(model) }
        if let harness { raw["requested_harness"] = .string(harness) }
        if let timeQualification { raw["time_qualification"] = .string(timeQualification) }
        if let wall { raw["wall_seconds"] = .number(wall) }
        if let usage {
            raw["accounting"] = .object([
                "version": .number(1), "state": .string("available"), "scope": .string("execution"),
                "additive": .bool(true), "contribution_id": .string("contribution-\(id)"), "total_tokens": .number(Double(usage)),
                "categories": .object(["input_tokens": .number(Double(usage)), "output_tokens": .number(0),
                    "cache_read_tokens": .number(0), "cache_creation_tokens": .number(0)])
            ])
        }
        return fact(raw)
    }

    func workflow(_ id: String, cohort: Double, wall: Double, repo: String = "/repo") -> StatisticsFact {
        fact(["id": .string(id), "kind": .string("workflow"), "status": .string("completed"),
            "started_at": .number(cohort), "finished_at": .number(cohort + wall), "cohort_started_at": .number(cohort),
            "wall_seconds": .number(wall), "workflow_id": .string("flow"), "workflow_name": .string("Flow"),
            "workflow_revision": .number(1), "repo_path": .string(repo), "root_workflow_run_id": .string(id)])
    }

    func snapshot(
        _ facts: [StatisticsFact], eligible: Int = 0, available: Int = 0,
        anchorDate: Date? = nil, calendar: Calendar? = nil
    ) -> StatisticsSnapshot {
        let page = StatisticsPage(raw: [
            "projection_version": .number(1), "state": .string("ready"), "snapshot_id": .string("s"),
            "generation": .string("g"), "observed_at": .string("now"), "items": .array([]), "has_more": .bool(false),
            "history_complete": .bool(true), "ownership_complete": .bool(true), "retained_history_only": .bool(true),
            "accounting_coverage": .object(["eligible_executions": .number(Double(eligible)), "available_executions": .number(Double(available))]),
            "retention": .object(["state": .string("days"), "days": .number(90)])
        ])!
        return StatisticsSnapshot(facts: facts, page: page, anchorDate: anchorDate, calendar: calendar)
    }

    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "America/Los_Angeles")!; return value
    }
}
