import Foundation
import MonitorCore

struct StartScreenSnapshot: Sendable {
    var tasks: [TaskInfo]?
    var runs: [[String: JSONValue]]?
    var definitions: [WorkflowRecord]
}

struct StartScreenRow: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var count: String?
}

struct StartScreenPresentation: Equatable, Sendable {
    var greeting: String
    var status: String?
    var rows: [StartScreenRow]
    var total: Int
}

enum StartScreenDerivation {
    static func greeting(hour: Int) -> String {
        switch hour {
        case 5 ..< 7: "Early start"
        case 7 ..< 12: "Good morning"
        case 12 ..< 18: "Good afternoon"
        case 18 ..< 23: "Good evening"
        default: "Working late"
        }
    }

    static func make(snapshot: StartScreenSnapshot, now: Date, calendar: Calendar) -> StartScreenPresentation {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let week = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let tasks = taskSummary(snapshot.tasks)
        let workflows = workflowSummary(snapshot.runs, cutoff: week, now: now)
        let taskRunning = tasks.running, workflowRunning = workflows.running
        let taskDates = tasks.dates, workflowDates = workflows.dates
        let tasksKnown = tasks.known, workflowsKnown = workflows.known
        var rankingKnown = workflows.rankingKnown
        let counts = workflows.counts
        if snapshot.definitions.contains(where: \.workflowID.isEmpty) { rankingKnown = false }
        let ordered = snapshot.definitions.sorted { left, right in
            let lhs = counts[left.workflowID, default: 0], rhs = counts[right.workflowID, default: 0]
            if rankingKnown, lhs != rhs { return lhs > rhs }
            let order = left.id.localizedCaseInsensitiveCompare(right.id)
            return order == .orderedSame ? left.workflowID < right.workflowID : order == .orderedAscending
        }
        let rows = ordered.prefix(3).map { definition in
            let count = counts[definition.workflowID, default: 0]
            return StartScreenRow(id: definition.id, name: definition.id,
                                  count: rankingKnown ? (count == 0 ? "Never run" : plural(count, "run")) : nil)
        }
        var status: String?
        if tasksKnown, workflowsKnown {
            let running = phrase(taskRunning, workflowRunning)
            var line = running.isEmpty ? "Nothing running." : "\(running) running."
            for (start, end, label) in [(today, now, "today"), (yesterday, today, "yesterday"), (week, now, "in the last 7 days")] {
                let tasks = taskDates.filter { $0 >= start && $0 <= now && ($0 < end || end == now) }.count
                let runs = workflowDates.filter { $0 >= start && $0 <= now && ($0 < end || end == now) }.count
                let finished = phrase(tasks, runs)
                if !finished.isEmpty { line += " \(finished) finished \(label)."; break }
            }
            status = line
        }
        return StartScreenPresentation(greeting: greeting(hour: calendar.component(.hour, from: now)), status: status,
                                       rows: rows, total: ordered.count)
    }

    private struct Summary {
        var running = 0
        var dates: [Date] = []
        var known = true
        var rankingKnown = true
        var counts: [String: Int] = [:]
    }

    private static let terminal = ["completed", "failed", "timed_out", "cancelled"]

    private static func taskSummary(_ items: [TaskInfo]?) -> Summary {
        var result = Summary(known: items != nil)
        for task in items ?? [] {
            guard let owner = task.raw["workflow_run_id"] else { result.known = false; continue }
            if owner != .null {
                if owner.stringValue?.isEmpty != false { result.known = false }
                continue
            }
            guard let status = task.raw["status"]?.stringValue else { result.known = false; continue }
            if status == "running" { result.running += 1 }
            guard terminal.contains(status) else { continue }
            guard let text = task.raw["finished_at"]?.stringValue, let date = ISODate.parse(text) else {
                result.known = false; continue
            }
            result.dates.append(date)
        }
        return result
    }

    private static func workflowSummary(_ items: [[String: JSONValue]]?, cutoff: Date, now: Date) -> Summary {
        var result = Summary(known: items != nil, rankingKnown: items != nil)
        for run in items ?? [] {
            guard let root = isRootSavedRun(run) else { result.known = false; result.rankingKnown = false; continue }
            guard root else { continue }
            if let id = run["workflow_id"]?.stringValue, !id.isEmpty {
                result.counts[id, default: 0] += 1
            } else {
                result.rankingKnown = false
            }
            addWorkflowActivity(run, cutoff: cutoff, now: now, to: &result)
        }
        return result
    }

    private static func isRootSavedRun(_ run: [String: JSONValue]) -> Bool? {
        guard let kind = run["kind"]?.stringValue, !kind.isEmpty else { return nil }
        if kind == "builder" { return false }
        guard let parent = run["parent_workflow_run_id"], parent != .null else { return true }
        guard let parentID = parent.stringValue else { return nil }
        return parentID.isEmpty ? nil : false
    }

    private static func addWorkflowActivity(_ run: [String: JSONValue], cutoff: Date, now: Date, to result: inout Summary) {
        guard let status = run["status"]?.stringValue, let settling = run["settling"]?.boolValue else {
            result.known = false; return
        }
        guard !settling else { return }
        if status == "running" { result.running += 1 }
        guard terminal.contains(status) else { return }
        if let value = run["finished_at"]?.doubleValue, value.isFinite {
            result.dates.append(Date(timeIntervalSince1970: value))
        } else if let updated = run["updated_at"]?.doubleValue, updated.isFinite,
                  let created = run["created_at"]?.doubleValue, created.isFinite,
                  created <= updated, updated <= now.timeIntervalSince1970,
                  Date(timeIntervalSince1970: updated) < cutoff {
            return
        } else { result.known = false }
    }

    private static func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
    private static func phrase(_ tasks: Int, _ workflows: Int) -> String {
        [tasks > 0 ? plural(tasks, "task") : nil, workflows > 0 ? plural(workflows, "workflow") : nil]
            .compactMap(\.self)
.joined(separator: " and ")
    }
}
