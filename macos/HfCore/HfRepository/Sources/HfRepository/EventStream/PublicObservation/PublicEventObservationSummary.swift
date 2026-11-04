import Foundation
import MonitorCore

// MARK: - PublicEventSummary

/// Internal observational totals. `observed` never certifies lossless engine capture.
struct PublicEventSummary: Equatable, Sendable {
    enum State: Equatable, Sendable { case loading, observed, unavailable, limited }
    let state: State
    let counts: ActivityCounts?
    let files: [EditedFile]
    let totalFiles: Int?
    let issues: Set<PublicEventSummaryIssue>
}

enum PublicEventSummaryIssue: Hashable, Sendable {
    case normalizationLoss, skippedRecords, gaps, captureUnavailable, unknownKind
    case unsupportedPayload, ambiguousOrder, ambiguousCall, capacity
    case historicalLimit, nonprogress, requestUnavailable
}

struct PublicEventSummaryLimits: Sendable {
    var files = 10000
    var pathBytes = 2 * 1024 * 1024
    var pendingCalls = 10000
    var callIDBytes = 1024 * 1024
    var keyBytes = 8192
    var publishedFiles = 100
}

// MARK: - PublicEventSummaryReducer

/// Chronological replay only. Seek pages contribute sticky concerns, never doubled counts.
struct PublicEventSummaryReducer: Sendable {
    private let limits: PublicEventSummaryLimits
    private var issues: Set<PublicEventSummaryIssue> = []
    private var counts = ActivityCounts()
    private var repoPath = ""
    private var order: [String] = []
    private var latest: [String: EditedFileStatus] = [:]
    private var latestCall: [String: String] = [:]
    private struct PendingCall: Sendable { let path: String? }
    private var pending: [String: PendingCall] = [:]
    private var pathBytes = 0
    private var callBytes = 0
    private var lastSeq: Int?

    init(limits: PublicEventSummaryLimits = PublicEventSummaryLimits()) { self.limits = limits }

    var isUnavailable: Bool { !issues.isEmpty }
    var isLimited: Bool { issues.contains(.capacity) || issues.contains(.historicalLimit) }

    mutating func qualify(_ issue: PublicEventSummaryIssue) { fail(issue) }

    mutating func noteSeek(_ page: TaskEventPage) { inspectCoverage(page) }

    mutating func fold(_ page: TaskEventPage) {
        inspectCoverage(page)
        guard !isUnavailable else { return }
        for record in page.events {
            guard lastSeq.map({ record.seq > $0 }) ?? true else { fail(.ambiguousOrder); return }
            lastSeq = record.seq
            guard record.truncated != true, record.oversized != true else { fail(.normalizationLoss); return }
            guard validPayload(record) else { fail(.unsupportedPayload); return }
            apply(record)
            if isUnavailable { return }
        }
    }

    func snapshot(caughtUp: Bool) -> PublicEventSummary {
        let state: PublicEventSummary.State = isLimited ? .limited : isUnavailable ? .unavailable : caughtUp ? .observed : .loading
        let available = state == .observed
        return PublicEventSummary(state: state, counts: available ? counts : nil,
                                  files: available ? order.prefix(max(0, limits.publishedFiles)).map {
                                      EditedFile(path: $0, status: latest[$0] ?? .unconfirmed)
                                  } : [], totalFiles: available ? order.count : nil, issues: issues)
    }

    private mutating func inspectCoverage(_ page: TaskEventPage) {
        if page.skipped.malformed > 0 || page.skipped.oversized > 0 { fail(.skippedRecords) }
        if !page.gaps.isEmpty { fail(.gaps) }
        if !["live", "observed_terminal"].contains(page.log.captureState)
            || [.incomplete, .unknown, .unavailable].contains(page.log.state) { fail(.captureUnavailable) }
        if page.events.contains(where: { $0.truncated == true || $0.oversized == true }) { fail(.normalizationLoss) }
    }

    private mutating func fail(_ issue: PublicEventSummaryIssue) {
        issues.insert(issue)
        // No partial keys survive as an apparently usable file/count projection.
        order.removeAll(); latest.removeAll(); latestCall.removeAll(); pending.removeAll()
        repoPath = ""; pathBytes = 0; callBytes = 0; counts = ActivityCounts()
    }

    private mutating func apply(_ record: TaskEventRecord) {
        switch record.kind {
        case "task_started":
            if let repo = record.raw["repo_path"]?.stringValue {
                guard repo.utf8.count <= limits.keyBytes else { fail(.capacity); return }
                if order.isEmpty { repoPath = repo }
            }
        case "tool_call": applyCall(record.raw)
        case "tool_result": applyResult(record.raw)
        case "assistant_text", "assistant_delta", "user_message", "notice", "usage", "task_finished", "undelivered": break
        default: fail(.unknownKind)
        }
    }

    private mutating func applyCall(_ raw: [String: JSONValue]) {
        guard let call = raw["call_id"]?.stringValue, let category = raw["category"]?.stringValue else { return }
        guard call.utf8.count <= limits.keyBytes else { fail(.capacity); return }
        guard pending[call] == nil else { fail(.ambiguousCall); return }
        guard pending.count < limits.pendingCalls, call.utf8.count <= limits.callIDBytes - callBytes else { fail(.capacity); return }
        guard incrementCounts(category: category) else { return }
        guard ["edit", "write"].contains(category) else {
            pending[call] = PendingCall(path: nil)
            callBytes += call.utf8.count
            return
        }
        addEdit(raw, call: call)
    }

    private mutating func addEdit(_ raw: [String: JSONValue], call: String) {
        guard let rawPath = raw["path"]?.stringValue, !rawPath.isEmpty else { fail(.unsupportedPayload); return }
        let prefix = repoPath.hasSuffix("/") ? repoPath : repoPath + "/"
        let path = !repoPath.isEmpty && rawPath.hasPrefix(prefix) ? String(rawPath.dropFirst(prefix.count)) : rawPath
        guard path.utf8.count <= limits.keyBytes else { fail(.capacity); return }
        if latest[path] == nil {
            guard order.count < limits.files, path.utf8.count <= limits.pathBytes - pathBytes else { fail(.capacity); return }
            order.append(path); pathBytes += path.utf8.count
        }
        pending[call] = PendingCall(path: path); callBytes += call.utf8.count
        latestCall[path] = call; latest[path] = .unconfirmed
    }

    private mutating func incrementCounts(category: String) -> Bool {
        guard counts.toolCalls < Int.max, counts.edits < Int.max, counts.commands < Int.max else { fail(.capacity); return false }
        counts.toolCalls += 1
        if category == "shell" { counts.commands += 1 }
        if ["edit", "write"].contains(category) { counts.edits += 1 }
        return true
    }

    private mutating func applyResult(_ raw: [String: JSONValue]) {
        guard let call = raw["call_id"]?.stringValue, let ok = raw["ok"]?.boolValue,
              let pendingCall = pending.removeValue(forKey: call) else { return }
        callBytes -= call.utf8.count
        if let path = pendingCall.path, latestCall[path] == call {
            latest[path] = ok ? .edited : .failed
            latestCall[path] = nil
        }
    }
}

// MARK: - Kind-specific admission

private extension PublicEventSummaryReducer {
    func validPayload(_ record: TaskEventRecord) -> Bool {
        let raw = record.raw
        switch record.kind {
        case "task_started":
            return strings(raw, required: ["prompt"], optional: ["repo_path", "backend", "freedom", "model", "reasoning_effort", "spawned_by", "group"])
                && optionalBool(raw["live_input"])
        case "assistant_text", "assistant_delta":
            return strings(raw, required: ["text"], optional: ["message_id"]) && optionalInteger(raw["block_index"])
        case "user_message": return strings(raw, required: ["text"], optional: ["source", "message_id"])
        case "notice": return strings(raw, required: ["text"], optional: [])
        case "tool_call": return validCall(raw)
        case "tool_result":
            return strings(raw, required: ["call_id", "output_tail"], optional: [])
                && raw["call_id"]?.stringValue?.isEmpty == false && raw["ok"]?.boolValue != nil && optionalInteger(raw["exit_code"])
        case "task_finished":
            return strings(raw, required: ["status"], optional: ["summary"]) && raw["status"]?.stringValue?.isEmpty == false
                && optionalInteger(raw["exit_code"]) && optionalBool(raw["observed"])
        case "undelivered":
            return strings(raw, required: ["message_id", "text", "reason"], optional: [])
        case "usage": return validUsage(raw)
        default: return true // `apply` records unknown semantics explicitly.
        }
    }

    func validCall(_ raw: [String: JSONValue]) -> Bool {
        guard strings(raw, required: ["call_id", "tool", "category", "input_preview"], optional: ["path", "command"]),
              ["call_id", "tool", "category"].allSatisfy({ raw[$0]?.stringValue?.isEmpty == false }) else { return false }
        guard let edit = raw["edit"], edit != .null else { return true }
        guard let object = edit.objectValue else { return false }
        return strings(object, required: [], optional: ["old", "new"])
    }

    func validUsage(_ raw: [String: JSONValue]) -> Bool {
        let cost = raw["total_cost_usd"]
        let turns = raw["num_turns"]
        let validCost = cost == nil || cost == .null || cost?.doubleValue.map { $0.isFinite && $0 >= 0 } == true
        return validCost && optionalInteger(turns) && (cost?.doubleValue != nil || turns?.wireIntegerValue != nil)
    }

    func strings(_ raw: [String: JSONValue], required: [String], optional: [String]) -> Bool {
        required.allSatisfy { raw[$0]?.stringValue != nil }
            && optional.allSatisfy { raw[$0] == nil || raw[$0] == .null || raw[$0]?.stringValue != nil }
    }

    func optionalBool(_ value: JSONValue?) -> Bool { value == nil || value == .null || value?.boolValue != nil }
    func optionalInteger(_ value: JSONValue?) -> Bool { value == nil || value == .null || value?.wireIntegerValue != nil }
}
