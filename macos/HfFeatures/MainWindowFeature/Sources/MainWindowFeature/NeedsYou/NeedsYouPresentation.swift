import Foundation
import HfRepository
import MonitorCore

// MARK: - NeedsYouRow

/// One list row. Age is not part of the model: a child view renders it from `waitingSince`.
struct NeedsYouRow: Equatable, Sendable, Identifiable {
    let id: String
    let kind: NeedsYouItem.Kind
    let kindLabel: String
    let title: String
    let pathTitles: [String]
    let startedBy: String
    let callerEnded: Bool
    let text: String
    let waitingSince: Date?
    /// Set while the row fades out after a local answer.
    var isLeaving = false

    /// Rows over this many characters clamp to three lines with Show more.
    static let longTextThreshold = 180
    var isLong: Bool { text.count > Self.longTextThreshold }
}

// MARK: - NeedsYouDetail

/// Everything the detail pane renders for one request.
struct NeedsYouDetail: Equatable, Sendable, Identifiable {
    enum Phase: Equatable, Sendable {
        case answerable, submitting
        case settled(decision: String, answer: String, note: String)
        case expired
    }

    struct Field: Equatable, Sendable, Identifiable {
        var id: String { label }
        let label: String
        let value: String
    }

    struct ApprovalBody: Equatable, Sendable {
        let title: String
        let fields: [CallerApprovalAction.Field]
    }

    let id: String
    let kind: NeedsYouItem.Kind
    let kindLabel: String
    let title: String
    let pathTitles: [String]
    let text: String
    let questionItems: [String]
    let offeredAnswers: [String]?
    let resumeHint: String?
    let approval: ApprovalBody?
    let provenance: [Field]
    let ownershipNote: String
    let canAddAttempts: Bool
    var phase: Phase
    var error: String?
    /// Shown when the approval was refreshed after it changed under the reviewer.
    var reviewNote: String?

    static let longTextThreshold = 900
    var isLong: Bool { kind != .approval && text.count > Self.longTextThreshold }
    var sourceLine: String { "\(kindLabel) · \(pathTitles.last ?? title)" }
}

// MARK: - NeedsYouPresentation

/// The whole screen state. Equality covers every rendered field so unchanged snapshots do not rewrite it.
struct NeedsYouPresentation: Equatable, Sendable {
    var isLoading = true
    var rows: [NeedsYouRow] = []
    var summary = ""
    /// Status notice, e.g. "The caller is answering this again."
    var notice: String?
    /// "Could not read N runs…" with a Retry action; real failures only.
    var partialNotice: String?
    /// Neutral line while sources are deferred, never an error.
    var checkingNote: String?
    var olderEngineNote: String?
    var detail: NeedsYouDetail?
    var detailIsLoading = false
    /// A request is selected: the detail pane replaces the list.
    var showsDetail = false
}

// MARK: - NeedsYouPresentationMapper

/// Pure, nonisolated mapping from repository values to presentation, run off the main actor.
enum NeedsYouPresentationMapper {
    static func kindLabel(_ kind: NeedsYouItem.Kind) -> String {
        switch kind {
        case .approval: "Approval"
        case .question: "Question"
        case .recovery: "Recovery"
        }
    }

    static func row(_ item: NeedsYouItem) -> NeedsYouRow {
        NeedsYouRow(id: item.id, kind: item.kind, kindLabel: kindLabel(item.kind), title: item.runTitle, pathTitles: item.pathTitles,
                    startedBy: item.startedBy, callerEnded: item.ownership.callerEnded, text: item.text, waitingSince: item.waitingSince)
    }

    static func summary(_ snapshot: NeedsYouSnapshot) -> String {
        if snapshot.phase == .loading, snapshot.items.isEmpty { return "Checking tasks and workflow runs…" }
        let count = snapshot.items.count
        if count == 0 { return "Nothing needs you" }
        return "\(snapshot.isLowerBound ? "At least " : "")\(count) \(count == 1 ? "request" : "requests") you can answer"
    }

    static func presentation(_ snapshot: NeedsYouSnapshot, leaving: Set<String>) -> NeedsYouPresentation {
        var value = NeedsYouPresentation()
        value.isLoading = snapshot.phase == .loading && snapshot.items.isEmpty
        value.rows = snapshot.items.map { item in
            var row = row(item)
            row.isLeaving = leaving.contains(item.id)
            return row
        }
        value.summary = summary(snapshot)
        if snapshot.unreadableSourceCount > 0 {
            let count = snapshot.unreadableSourceCount
            value.partialNotice = "Could not read \(count) \(count == 1 ? "run" : "runs"). Showing the requests Harflow could read."
        } else if snapshot.deferredSourceCount > 0 {
            value.checkingNote = "Checking more runs…"
        }
        if snapshot.workflowInputsUnsupported {
            value.olderEngineNote = "This engine version cannot report workflow questions here. Only task approvals are listed."
        }
        return value
    }

    static func ownershipNote(_ item: NeedsYouItem) -> String {
        let caller = "The original caller"
        if item.kind == .approval, item.rootRunID.isEmpty {
            return item.approval?.isMonitorOwned == true
                ? "Harflow owns this run, so you can answer here."
                : "Harflow sends your decision to the engine in place of \(caller.lowercased())."
        }
        if item.ownership.owner == "monitor" {
            return "Harflow owns this run, so you can answer here."
                + (item.ownership.handover != nil ? " \(caller) can no longer answer it." : "")
        }
        return "\(caller) has ended. Answering hands this run to Harflow, and \(caller.lowercased()) can no longer answer it. "
            + "Harflow checks again when you send, and the engine may refuse."
    }

    static func provenance(_ item: NeedsYouItem) -> [NeedsYouDetail.Field] {
        var fields: [NeedsYouDetail.Field] = [.init(label: "Run", value: item.runTitle)]
        fields.append(.init(label: "Path", value: item.pathTitles.count > 1 ? item.pathTitles.joined(separator: " › ") : "Task"))
        fields.append(.init(label: "Started by", value: item.startedBy))
        if item.ownership.callerEnded { fields.append(.init(label: "Caller", value: "Ended")) }
        let owner = if item.kind == .approval, item.rootRunID.isEmpty, item.approval?.isMonitorOwned != true {
            "Harflow responds for the caller"
        } else if item.ownership.owner == "monitor" {
            "Harflow"
        } else {
            "The original caller (ended); Harflow takes over when you answer"
        }
        fields.append(.init(label: "Owner", value: owner))
        if let since = item.waitingSince {
            fields.append(.init(label: "Waiting since", value: since.formatted(date: .abbreviated, time: .shortened)))
        }
        if !item.ownership.engineNote.isEmpty { fields.append(.init(label: "Engine note", value: item.ownership.engineNote)) }
        if let handover = item.ownership.handover {
            var parts: [String] = []
            if let when = handover.timestamp { parts.append(when.formatted(date: .abbreviated, time: .shortened)) }
            if !handover.previousOwner.isEmpty { parts.append("Previous owner: \(handover.previousOwner)") }
            if !handover.reason.isEmpty { parts.append(handover.reason) }
            fields.append(.init(label: "Handover", value: parts.joined(separator: ". ")))
        }
        return fields
    }

    static func detail(_ item: NeedsYouItem) -> NeedsYouDetail {
        let body = item.approval.map { request -> NeedsYouDetail.ApprovalBody in
            let action = CallerApprovalAction.build(request)
            return .init(title: action.title, fields: action.fields)
        }
        return NeedsYouDetail(
            id: item.id, kind: item.kind, kindLabel: kindLabel(item.kind), title: item.runTitle, pathTitles: item.pathTitles,
            text: item.text, questionItems: item.questionItems, offeredAnswers: item.offeredAnswers, resumeHint: item.resumeHint,
            approval: body, provenance: provenance(item), ownershipNote: ownershipNote(item), canAddAttempts: item.canAddAttempts,
            phase: .answerable, error: nil, reviewNote: nil
        )
    }

    static func settledNote(_ item: NeedsYouItem) -> String {
        if item.kind == .approval, item.rootRunID.isEmpty {
            return "Harflow sent your decision to the engine, and \(item.runTitle) no longer needs you."
        }
        if item.ownership.callerEnded || item.ownership.handover != nil {
            return "Harflow now owns this run. The original caller can no longer answer it, and \(item.runTitle) no longer needs you."
        }
        return "\(item.runTitle) no longer needs you."
    }

    static func settledDecision(_ item: NeedsYouItem, rejected: Bool) -> String {
        switch item.kind {
        case .approval: rejected ? "Rejected" : "Approved once"
        case .recovery: "Resumed with answer"
        case .question: "Answered"
        }
    }
}
