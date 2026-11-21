import Foundation
import HfUI
import MonitorCore

// MARK: - WorkflowSteeringPresentation

/// Display evidence only. Action authority remains with the captured repository observation.
struct WorkflowSteeringPresentation: Equatable, Sendable {
    struct Message: Equatable, Sendable, Identifiable {
        let id: Int64
        let isCaller: Bool
        let text: String
    }

    var statusLine: String?
    var note: String?
    var reason: String?
    var caption: String?
    var placeholder = "Messages are unavailable right now."
    var messages: [Message] = []
    var action: WorkflowSteeringAction?
    var canDismiss = false
    var opensNeedsYou = false
    var partialHistory = false
    var isHeld = false
    var isDismissed = false
    var dismissedEpisodeID: String?
    var resumeReason: String?

    static let parkedReason = "Conversation is waiting for caller; use steering capability"

    static func isRegularRoot(_ raw: [String: JSONValue]) -> Bool {
        let run = WorkflowRunModel(raw: raw)
        return !run.id.isEmpty && !run.isBuilder && run.parentRunID == nil && run.rootRunID == run.id
    }

    static func hasPositiveHold(_ raw: [String: JSONValue]) -> Bool {
        guard isRegularRoot(raw) else { return false }
        if let hold = raw["steering_summary"]?["hold"]?.boolValue { return hold }
        return (raw["pending_steering_count"]?.intValue ?? 0) > 0
    }

    static func hasPendingQuestion(_ raw: [String: JSONValue]) -> Bool {
        let status = WorkflowMonitorStatus(raw)
        if status.hasPendingInputsKey { return !status.pendingInputs.isEmpty }
        guard let decision = status.inputDecisionID,
              status.inputQuestion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return false }
        let recovery = status.usageLimitRecovery ?? WorkflowUsageLimitRecovery(raw["orchestrator_usage_recovery"])
        return status.status == "needs_input" || (status.status == "needs_attention" && recovery?.decisionID == decision)
    }

    static func hidesParkedReason(_ raw: [String: JSONValue], dismissed: Bool = false) -> Bool {
        guard raw["kind"]?.stringValue != "builder", raw["status"]?.stringValue == "paused",
              raw["attention_reason"]?.stringValue == parkedReason || raw["reason"]?.stringValue == parkedReason,
              hasPositiveHold(raw) || dismissed, !hasPendingQuestion(raw),
              raw["attention_checkpoint_id"]?.stringValue?.isEmpty != false,
              (raw["approval_summary"]?["pending_count"]?.intValue ?? 0) == 0 else { return false }
        return true
    }

    static func make(status: WorkflowSteeringStatus?, run: WorkflowRunModel, history: [WorkflowSteeringHistoryItem],
                     observedAt: Date, unresolved: Bool = false, partialHistory: Bool = false, auditedProducer: Bool = false) -> Self {
        var result = Self()
        result.partialHistory = partialHistory
        result.isHeld = hasPositiveHold(run.raw)
        guard let status, status.rootID == run.id else {
            _ = result.applyPhase(run.status)
            return result
        }
        let episode = status.heldRootEpisode ?? status.episodes.last { $0.target.isRootOrchestrator }
        result.isHeld = status.episodes.contains(where: \.hold)
        result.canDismiss = status.permits(.dismiss)
        result.isDismissed = episode?.state == "dismissed" && !result.isHeld
        result.dismissedEpisodeID = result.isDismissed ? episode?.id : nil
        result.resumeReason = run.raw["monitor_controls"]?["resume"]?["reason"]?.stringValue
        let rows = scopedRows(history, status: status, episode: episode)
        result.messages = conversation(rows, episode: episode)
        if result.applyPhase(run.status) { return result }
        if status.refusalCodes?.contains("steering_question_pending") == true, hasPendingQuestion(run.raw) {
            result.placeholder = "Answer the run's open question first."
            result.opensNeedsYou = true
        } else if unresolved || episode?.state == "delivery_unknown" {
            result.statusLine = "Delivery unknown"
            result.placeholder = "Messages are off until delivery is settled"
        } else {
            result.applyEpisode(episode, status: status, rows: rows, observedAt: observedAt, auditedProducer: auditedProducer)
        }
        return result
    }

    private static func scopedRows(_ history: [WorkflowSteeringHistoryItem], status: WorkflowSteeringStatus,
                                   episode: WorkflowSteeringEpisode?) -> [WorkflowSteeringHistoryItem] {
        guard let episode else { return [] }
        return history.filter { $0.sequence <= status.sequence && ($0.episodeID == episode.id || $0.episodeID == nil) }.sorted { $0.sequence < $1.sequence }
    }

    private static func conversation(_ rows: [WorkflowSteeringHistoryItem], episode: WorkflowSteeringEpisode?) -> [Message] {
        let classifications = rows.filter { $0.kind == "classified" }
        return rows.compactMap { row in
            guard row.episodeID == episode?.id, let text = row.text else { return nil }
            if row.kind == "requested", ["open", "reply", "retarget"].contains(row.action ?? "") {
                return Message(id: row.sequence, isCaller: true, text: text)
            }
            if row.kind == "final_captured", let turn = row.turnID,
               classifications.contains(where: { $0.turnID == turn && $0.sequence > row.sequence && $0.outcome == "conversation" }) {
                return Message(id: row.sequence, isCaller: false, text: text)
            }
            return nil
        }
    }

    mutating func applyPhase(_ phase: String) -> Bool {
        guard ["cancelled", "completed", "cancelling", "failed"].contains(phase) else { return false }
        action = nil
        statusLine = nil
        note = nil
        reason = nil
        caption = nil
        placeholder = "Messages are unavailable right now."
        switch phase {
        case "cancelled":
            statusLine = "The run was cancelled."
            placeholder = MessageBoxDisabledReason.runCancelled.text
        case "completed": placeholder = MessageBoxDisabledReason.runCompleted.text
        case "cancelling":
            statusLine = "Cancelling the run…"
            placeholder = MessageBoxDisabledReason.runCancelling.text
        case "failed": break
        default: return false
        }
        return true
    }

    private mutating func applyEpisode(_ episode: WorkflowSteeringEpisode?, status: WorkflowSteeringStatus,
                                       rows: [WorkflowSteeringHistoryItem], observedAt: Date, auditedProducer: Bool) {
        switch episode?.state {
        case "classifying", "queued_boundary", "turn_reserved", "discussing":
            statusLine = "Waiting for the orchestrator to respond"
            placeholder = "One conversation at a time — wait for the reply"
        case "dismiss_pending_settlement", "dismissing":
            statusLine = "Dismissing — waiting for running work to settle"
            canDismiss = false
        case "stale", "expired", "awaiting_caller", "command_refused":
            applyWaiting(episode, status: status, rows: rows, observedAt: observedAt, auditedProducer: auditedProducer)
        case "dismissed":
            statusLine = "Conversation dismissed"
            if status.permits(.open) {
                action = .open
                placeholder = "Message the orchestrator"
                caption = "Your next message starts a new conversation."
            }
        case nil:
            if status.permits(.open) { action = .open; placeholder = "Message the orchestrator" }
        default: break
        }
    }

    private mutating func applyWaiting(_ episode: WorkflowSteeringEpisode?, status: WorkflowSteeringStatus,
                                       rows: [WorkflowSteeringHistoryItem], observedAt: Date, auditedProducer: Bool) {
        if episode?.state == "command_refused" {
            note = "The orchestrator couldn't carry out that request. Reply to continue."
            reason = Self.refusalReason(rows, episode: episode)
        }
        applyExplicitExpiryNote(episode)
        if status.permits(.retarget) {
            action = .retarget
            caption = "Your next message starts a new conversation."
            placeholder = "Message the orchestrator"
            let timed = status.schemaVersion == 2 && auditedProducer
                || episode?.createdAt.map { observedAt.timeIntervalSince1970 - $0 >= 1800 } == true
            if episode?.state != "stale", timed {
                note = Self.expiredNote
                reason = nil
            } else if episode?.state == "command_refused" {
                note = nil
                reason = nil
                statusLine = "The run is waiting for you."
            } else if note == nil { statusLine = "The run is waiting for you." }
        } else if status.permits(.reply) {
            action = .reply
            placeholder = "Reply to the orchestrator"
            if note == nil { statusLine = "The orchestrator asked a question. Reply to continue." }
        }
    }

    private static let expiredNote = "This conversation expired after 30 minutes. The run waits for you until you dismiss it or send a new message."

    private mutating func applyExplicitExpiryNote(_ episode: WorkflowSteeringEpisode?) {
        if episode?.state == "stale" { note = "The run moved on since this conversation started." }
        if episode?.state == "expired" { note = Self.expiredNote }
    }

    private static func refusalReason(_ rows: [WorkflowSteeringHistoryItem], episode: WorkflowSteeringEpisode?) -> String {
        let final = rows.first { $0.kind == "final_captured" && episode?.latestReplyReference == "history:\($0.sequence)" }
        let classified = final.flatMap { final in
            rows.last { $0.kind == "classified" && $0.turnID == final.turnID && $0.sequence > final.sequence && $0.outcome != "conversation" }
        }
        return classified?.outcome ?? "The refusal reason is unavailable."
    }

}

// MARK: - WorkflowSteeringHistoryProgress

/// Bounded recent display rows and a continuation proven by received public rows.
struct WorkflowSteeringHistoryProgress {
    var rows: [WorkflowSteeringHistoryItem] = []
    var cursor: String?
    var sequence: Int64 = -1
    var floor: Int64?
    var incomplete = false
    var catchingUp = true

    mutating func consume(_ page: WorkflowSteeringHistoryPage, horizon: Int64) -> Bool {
        let valid = page.items.filter { $0.sequence <= horizon }
        let previous = cursor
        for row in valid where !rows.contains(where: { $0.sequence == row.sequence }) { rows.append(row) }
        rows.sort { $0.sequence < $1.sequence }
        rows = Array(rows.suffix(400))
        incomplete = incomplete || page.gap || page.historyIncomplete
        if let next = page.continuationCursor(atOrBefore: horizon) { cursor = next }
        catchingUp = page.hasMore && page.items.last.map { $0.sequence <= horizon } == true
        if catchingUp, cursor == previous { incomplete = true; catchingUp = false }
        return catchingUp
    }
}
