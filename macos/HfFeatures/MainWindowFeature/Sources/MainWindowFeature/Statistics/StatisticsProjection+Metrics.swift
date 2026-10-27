import Foundation
import MonitorCore

// MARK: - Statistics metrics and coverage

extension StatisticsProjection {
    static func other(_ measure: StatisticsMeasure) -> StatisticsMeasure { measure == .time ? .usage : .time }
    static func fraction(_ value: Double, _ maximum: Double) -> Double { maximum > 0 ? min(1, max(0, value / maximum)) : 0 }
    static func value(_ facts: [StatisticsFact], measure: StatisticsMeasure, wall: Bool) -> Double? {
        if measure == .usage { return usage(facts) }
        let contributing = facts.filter { $0.kind == "workflow" ? wall : $0.raw["duration_additive"]?.boolValue == true }
        if contributing.isEmpty { return facts.isEmpty ? 0 : nil }
        var total = 0.0
        for fact in contributing {
            let field = wall && fact.kind == "workflow" ? "wall_seconds" : "execution_seconds"
            guard let duration = fact.number(field), (total + duration).isFinite else { return nil }
            total += duration
        }
        return total
    }

    static func usage(_ facts: [StatisticsFact]) -> Double? {
        var total = 0, seen: Set<String> = []
        for fact in facts {
            guard fact.raw["usage_additive"]?.boolValue == true,
                  let contribution = fact.accounting["contribution_id"]?.stringValue, !contribution.isEmpty,
                  let count = fact.comparableTokens else { continue }
            guard seen.insert(contribution).inserted else { continue }
            let addition = total.addingReportingOverflow(count)
            guard !addition.overflow else { return nil }; total = addition.partialValue
        }
        return seen.isEmpty ? nil : Double(total)
    }

    static func formatted(_ value: Double?, measure: StatisticsMeasure) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        if measure == .usage { return value.formatted(.number.precision(.fractionLength(0))) + " tokens" }
        if value >= 3600 { return String(format: "%.1f h", value / 3600) }
        if value >= 60 { return String(format: "%.1f min", value / 60) }
        return String(format: "%.0f s", value)
    }

    static func metricLabel(_ facts: [StatisticsFact], measure: StatisticsMeasure, wall: Bool) -> String {
        if !facts.isEmpty, facts.allSatisfy({ $0.kind == "execution" && $0.raw["duration_additive"]?.boolValue == false }),
           value(facts, measure: measure, wall: wall) == nil { return "Owner-included" }
        return formatted(value(facts, measure: measure, wall: wall), measure: measure)
    }

    static func accountingCoverage(_ facts: [StatisticsFact], label: String) -> String {
        let independent = facts.filter { $0.raw["duration_additive"]?.boolValue == true || $0.raw["usage_additive"]?.boolValue == true }
        let known = independent.filter { $0.comparableTokens != nil }.count
        let state = known == 0 ? "Unavailable" : known == independent.count ? "Complete" : "Partial"
        return "\(label) accounting: \(state) · \(known) of \(independent.count) independent executions · \(facts.count) execution records."
    }

    static func coverage(_ snapshot: StatisticsSnapshot, selected: [StatisticsFact], label: String) -> [String] {
        var lines = ["Retained history only.", accountingCoverage(selected, label: label)]
        switch snapshot.page.retentionState {
        case "days": lines
            .append("Retention: \(snapshot.page.retentionDays.map(String.init) ?? "unknown") days; selected ranges may exceed retained history.")
        case "disabled": lines.append("History retention is disabled.")
        default: lines.append("History retention window is unknown.")
        }
        if selected.contains(where: { $0.raw["duration_additive"]?.boolValue == true && $0.text("time_qualification") != "qualified_waits" }) {
            lines.append("Execution time uses elapsed time where waits are unproven; user waits may be included.")
        }
        let native = selected.filter { $0.raw["duration_additive"]?.boolValue == false }.count
        if native > 0 { lines.append("\(native) native logical records reference owner contributions and are not added again.") }
        lines.append("Requested models only. Unknown is not an observed or effective model.")
        lines += categoryCoverage(selected)
        lines += snapshot.page.diagnostics
        return lines
    }

    static func categoryCoverage(_ executions: [StatisticsFact]) -> [String] {
        let groups = Dictionary(grouping: executions, by: requestedHarnessID)
        return groups.keys.sorted().map { identity in
            let facts = groups[identity] ?? []
            let fields = ["input_tokens", "output_tokens", "cache_read_tokens", "cache_creation_tokens"]
            let labels = ["input", "output", "cache read", "cache creation"]
            let parts = zip(fields, labels).map { field, label in categorySubtotal(facts, field: field, label: label) }
            return "\(facts.first?.text("requested_harness") ?? "Unknown") category subtotal · " + parts.joined(separator: " · ")
        }
    }

    static func categorySubtotal(_ facts: [StatisticsFact], field: String, label: String) -> String {
        var total = 0, covered = 0, seen: Set<String> = []
        let eligible = facts.filter { $0.raw["duration_additive"]?.boolValue == true || $0.raw["usage_additive"]?.boolValue == true }.count
        for fact in facts {
            guard fact.raw["usage_additive"]?.boolValue == true, fact.accounting["state"]?.stringValue == "available",
                  fact.accounting["scope"]?.stringValue == "execution", fact.accounting["additive"]?.boolValue == true,
                  let identity = fact.accounting["contribution_id"]?.stringValue, !identity.isEmpty,
                  let amount = fact.accounting["categories"]?[field]?.wireIntegerValue, amount >= 0,
                  seen.insert(identity).inserted else { continue }
            let addition = total.addingReportingOverflow(amount)
            guard !addition.overflow else { return "\(label): unavailable (overflow)" }
            total = addition.partialValue; covered += 1
        }
        return "\(label): \(covered > 0 ? String(total) : "unavailable") (\(covered)/\(eligible))"
    }
}
