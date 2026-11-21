import Foundation

// MARK: - Statistics reported cost

/// A qualified execution cost, kept separate from duration and token additivity.
public enum StatisticsReportedCost: Equatable, Sendable {
    case unqualified, invalid, excluded, unavailable
    case reported(Double)
}

/// Whole-generation reported-cost coverage, repeated identically on every page.
public struct StatisticsCostCoverage: Equatable, Sendable {
    public let eligibleExecutions: Int
    public let availableExecutions: Int

    public init(eligibleExecutions: Int, availableExecutions: Int) {
        self.eligibleExecutions = eligibleExecutions
        self.availableExecutions = availableExecutions
    }
}

// MARK: - StatisticsFact

/// A bounded engine-owned history fact. Unknown tagged values remain explicit strings.
public struct StatisticsFact: Equatable, Sendable, Identifiable {
    public let raw: [String: JSONValue]
    public var id: String { text("id") ?? "" }
    public var kind: String { text("kind") ?? "unknown" }
    public var accounting: [String: JSONValue] { raw["accounting"]?.objectValue ?? [:] }
    public let reportedCost: StatisticsReportedCost
    public init(raw: [String: JSONValue], costQualified: Bool = false) {
        self.raw = raw
        reportedCost = costQualified ? Self.decodeCost(raw) : .unqualified
    }

    private static func decodeCost(_ raw: [String: JSONValue]) -> StatisticsReportedCost {
        guard raw["kind"]?.stringValue == "execution" else { return .excluded }
        guard let kind = raw["execution_kind"]?.stringValue,
              let additive = raw["cost_additive"]?.boolValue else { return .invalid }
        let explicitlyAbsent = raw["cost_usd"] == .null && raw["cost_provenance"] == .null
        if kind == "native" { return explicitlyAbsent && !additive ? .excluded : .invalid }
        guard ["initial", "resume", "continuation", "control"].contains(kind),
              let task = raw["task_id"]?.stringValue, !task.isEmpty else { return .invalid }
        if explicitlyAbsent && !additive { return .unavailable }
        guard additive, raw["cost_provenance"]?.stringValue == "backend_reported",
              let value = raw["cost_usd"]?.doubleValue, value.isFinite, value >= 0 else { return .invalid }
        return .reported(value)
    }
    public func text(_ key: String) -> String? { raw[key]?.stringValue }
    public func number(_ key: String) -> Double? {
        guard let value = raw[key]?.doubleValue, value.isFinite, value >= 0 else { return nil }
        return value
    }
    /// Only explicitly qualified execution-local contributions can enter additive usage.
    public var comparableTokens: Int? {
        guard kind == "execution", raw["usage_additive"]?.boolValue == true,
              accounting["version"]?.wireIntegerValue == 1,
              accounting["state"]?.stringValue == "available",
              accounting["scope"]?.stringValue == "execution",
              accounting["additive"]?.boolValue == true,
              let value = accounting["total_tokens"]?.wireIntegerValue, value >= 0 else { return nil }
        var sum = 0
        for key in ["input_tokens", "output_tokens", "cache_read_tokens", "cache_creation_tokens"] {
            guard let category = accounting["categories"]?[key]?.wireIntegerValue, category >= 0 else { return nil }
            let next = sum.addingReportingOverflow(category)
            guard !next.overflow else { return nil }; sum = next.partialValue
        }
        return sum == value ? value : nil
    }

    /// Terminal timeouts are failed outcomes while preserving their original wire status.
    public var isFailureOutcome: Bool { ["failed", "timed_out"].contains(text("status") ?? "") }

    /// Future kinds/statuses cannot silently contribute to finished-history totals.
    public var isSupportedTerminalFact: Bool {
        guard !id.isEmpty, ["workflow", "execution"].contains(kind),
              ["completed", "failed", "cancelled", "timed_out"].contains(text("status") ?? ""),
              number("cohort_started_at") != nil,
              let start = number("started_at"), let end = number("finished_at"), end >= start else { return false }
        if kind == "execution" {
            return raw["duration_additive"]?.boolValue != nil && raw["usage_additive"]?.boolValue != nil
        }
        return true
    }
}

// MARK: - StatisticsPage

/// One bounded page. Completeness is independent from accounting availability.
public struct StatisticsPage: Equatable, Sendable {
    public let state: String
    public let snapshotID: String?
    public let generation: String?
    public let observedAt: String
    public let items: [StatisticsFact]
    public let nextCursor: String?
    public let hasMore: Bool
    public let historyComplete: Bool
    public let ownershipComplete: Bool
    public let eligibleExecutions: Int
    public let availableExecutions: Int
    public let retentionState: String
    public let retentionDays: Int?
    public let diagnostics: [String]
    public let costQualified: Bool
    public let costCoverage: StatisticsCostCoverage?

    public init?(raw: [String: JSONValue], costQualified: Bool = false) {
        guard raw["projection_version"]?.wireIntegerValue == 1,
              let state = raw["state"]?.stringValue,
              let values = raw["items"]?.arrayValue, values.count <= 100,
              values.allSatisfy({ $0.objectValue != nil }),
              let observed = raw["observed_at"]?.stringValue,
              let more = raw["has_more"]?.boolValue,
              let history = raw["history_complete"]?.boolValue,
              let ownership = raw["ownership_complete"]?.boolValue,
              raw["retained_history_only"]?.boolValue == true,
              let coverage = raw["accounting_coverage"]?.objectValue,
              let eligible = coverage["eligible_executions"]?.wireIntegerValue, eligible >= 0,
              let available = coverage["available_executions"]?.wireIntegerValue, available >= 0, available <= eligible,
              let retention = raw["retention"]?.objectValue,
              let retentionState = retention["state"]?.stringValue else { return nil }
        self.state = state; snapshotID = raw["snapshot_id"]?.stringValue
        generation = raw["generation"]?.stringValue; observedAt = observed
        self.costQualified = costQualified
        if costQualified, let coverage = raw["cost_coverage"]?.objectValue,
           let eligible = coverage["eligible_executions"]?.wireIntegerValue, eligible >= 0,
           let available = coverage["available_executions"]?.wireIntegerValue, available >= 0, available <= eligible {
            costCoverage = .init(eligibleExecutions: eligible, availableExecutions: available)
        } else {
            costCoverage = nil
        }
        items = values.compactMap { value in
            value.objectValue.map { StatisticsFact(raw: $0, costQualified: costQualified) }
        }
        nextCursor = raw["next_cursor"]?.stringValue; hasMore = more
        historyComplete = history; ownershipComplete = ownership
        eligibleExecutions = eligible; availableExecutions = available
        self.retentionState = retentionState; retentionDays = retention["days"]?.wireIntegerValue
        diagnostics = raw["diagnostics"]?.arrayValue?.compactMap { $0["message"]?.stringValue } ?? []
        guard !more || nextCursor.map({ !$0.isEmpty && $0.utf8.count <= 4096 }) == true,
              more || nextCursor == nil,
              state != "ready" || (snapshotID != nil && generation != nil),
              items.allSatisfy(\.isSupportedTerminalFact) else { return nil }
    }
}

public extension CtlClient {
    /// Requires a fresh capability handshake on every page; older paired engines stay unsupported.
    func statisticsPage(since: String, before: String, cursor: String? = nil) async -> Result<StatisticsPage, ToolError> {
        var options = ["--since=\(since)", "--before=\(before)", "--limit=100"]
        if let cursor { options.append("--cursor=\(cursor)") }
        return await callWithCapabilities("statistics-page", options: options,
                                          requiringCapability: "statistics-page.v1").flatMap { response in
            Result<CtlDocument, ToolError>.success(response.document).requiringSuccess().flatMap { document in
                guard case .result(let payload) = document else {
                    return .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "statistics-page returned no result"))
                }
                return Self.decodeStatisticsPage(payload, costQualified: response.capabilities.contains(CtlCapability.statisticsCostModel))
            }
        }
    }

    private static func decodeStatisticsPage(_ payload: [String: JSONValue], costQualified: Bool) -> Result<StatisticsPage, ToolError> {
        guard JSONValue.object(payload).rendered().utf8.count <= 256 * 1024,
              let page = StatisticsPage(raw: payload, costQualified: costQualified) else {
            return .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Invalid Statistics page"))
        }
        return .success(page)
    }
}
