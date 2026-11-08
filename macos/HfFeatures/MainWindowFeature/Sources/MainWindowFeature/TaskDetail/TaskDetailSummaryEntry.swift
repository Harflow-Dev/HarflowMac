//
//  TaskDetailSummaryEntry.swift
//  MainWindowFeature
//
//  Whether the standalone transcript closes with a "Summary" entry. The decision runs off the main actor
//  in `TaskDetailTimelineBuilder.build`; the previous decision rides in the input so a transient currentness
//  change does not withdraw an entry that was already decided.
//

import Foundation
import HfRepository
import MonitorCore

// MARK: - SummaryEntryDecision

/// A decided Summary entry: made for one member, one raw reported summary and one observation source, then shown or suppressed.
struct SummaryEntryDecision: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// The entry is drawn.
        case shown
        /// The reported summary equals the final assistant message, so the entry would only repeat it.
        case suppressed
    }

    /// The conversation's current member the decision was made for.
    let memberID: String
    /// The raw reported summary (snapshot first, else the listing's) the decision was made on.
    let rawSummary: String
    /// The observation scope (session, source, window) the decision was made in. A source adoption or window reset
    /// changes it, so a decision never survives one.
    let scope: EventObservationScope
    let outcome: Outcome
}

// MARK: - TaskDetailSummaryEntryRule

enum TaskDetailSummaryEntryRule {

    /// The reasons that make the final message unprovable: any of them leaves the entry undecided.
    nonisolated static let lossReasons: Set<EventObservationReason> = [
        .unsupportedPayload, .normalizationLoss, .skippedRecords, .gaps, .ambiguousOrder
    ]

    /// The decision for `input`, or `nil` when the entry is not shown and not decided (withheld).
    ///
    /// Gates applied on every build: the standalone mount; the conversation's current member; a completed
    /// task with a completed snapshot of that member; a non-blank projected summary; no managed-workflow
    /// result error; a final log. A decision already made for the same member, raw summary and observation
    /// source (`EventObservationFrame.scope`) is then kept as it is, whatever the history's currentness
    /// or drain state, and its duplicate check is never repeated. Only establishing a new decision needs
    /// the rest: no evidence-loss reason, text evidence (no text item with older history waits for paging),
    /// complete history, and a byte-for-byte comparison of the raw summary with the member's last assistant
    /// text, which suppresses the entry unless that text is still streaming.
    nonisolated static func decide(_ input: TaskDetailTimelineInput) -> SummaryEntryDecision? {
        evaluate(input).decision
    }

    /// `decide`, with the text to draw when the decision is `.shown`; the projection runs once.
    nonisolated static func evaluate(_ input: TaskDetailTimelineInput) -> (decision: SummaryEntryDecision?, text: String?) {
        guard input.showsSummaryEntry,
              let member = input.members.last, member.task.taskID == input.task.taskID,
              input.task.status == .completed,
              let snapshot = input.snapshot, snapshot.taskID == input.task.taskID, snapshot.status == .completed,
              WorkflowNodePresentation.resultError(input.task) == nil,
              let raw = TaskReportedSummary.raw(snapshot: snapshot, task: input.task),
              let text = projectedText(input, raw: raw),
              let frame = member.observation, frame.logState == .final else { return (nil, nil) }
        if let previous = input.previousSummaryDecision, previous.memberID == member.task.taskID,
           previous.rawSummary.utf8.elementsEqual(raw.utf8), previous.scope == frame.scope {
            return (previous, previous.outcome == .shown ? text : nil)
        }
        guard frame.history.reasons.isDisjoint(with: lossReasons) else { return (nil, nil) }
        let final = lastText(member.items)
        if final == nil, frame.history.hasOlder { return (nil, nil) }
        guard frame.history.forwardDrained, frame.history.caughtUp, frame.history.currentness == .current else { return (nil, nil) }
        var outcome = SummaryEntryDecision.Outcome.shown
        if let final, !final.streaming, raw.utf8.elementsEqual(final.text.utf8) { outcome = .suppressed }
        let decision = SummaryEntryDecision(memberID: member.task.taskID, rawSummary: raw, scope: frame.scope, outcome: outcome)
        return (decision, outcome == .shown ? text : nil)
    }

    // MARK: - Private

    /// The projected summary; a whitespace-only text counts as empty.
    private nonisolated static func projectedText(_ input: TaskDetailTimelineInput, raw: String) -> String? {
        guard let text = TaskReportedSummary.projected(raw: raw, task: input.task, isWorkflowBuilder: input.isBuilder),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// The last `.text` item of any kind in the member's raw projector items.
    private nonisolated static func lastText(_ items: [TimelineItem]) -> (text: String, streaming: Bool)? {
        for item in items.reversed() {
            if case .text(let text, let streaming) = item.body { return (text, streaming) }
        }
        return nil
    }
}
