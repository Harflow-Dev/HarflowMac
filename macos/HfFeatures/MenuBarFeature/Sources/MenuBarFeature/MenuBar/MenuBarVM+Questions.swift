//
//  MenuBarVM+Questions.swift
//  MenuBarFeature
//

import Foundation
import HfRepository
import SwiftUI

// MARK: - HeldQuestion

/// A settled or unknown card kept after its item left the snapshot, so the card stays until the popover closes.
struct MenuBarHeldQuestion {
    let row: MenuBarNeedsYouSection.Row
    let index: Int
}

// MARK: - MenuBarVM + Questions

extension MenuBarVM {
    func didEditAnswer(_ rowID: String, text: String) {
        guard let index = needsYou?.rows.firstIndex(where: { $0.id == rowID }),
              let state = needsYou?.rows[index].question, state.fieldEnabled, state.draft != text else { return }
        questionDrafts[rowID] = text
        needsYou?.rows[index].question?.draft = text
    }

    func didSubmitAnswer(_ rowID: String) {
        guard let row = needsYou?.rows.first(where: { $0.id == rowID }), let item = row.item, let state = row.question,
              state.canSubmit, let source = needsYouSource else { return }
        let draft = state.draft
        let index = needsYou?.rows.firstIndex(where: { $0.id == rowID }) ?? 0
        questionPhases[rowID] = .submitting
        announce(.submitting)
        updateNeedsYou(source.needsYouSnapshot)
        Task { [weak self] in
            let outcome = await source.answerQuestion(item, text: draft)
            guard let self else { return }
            finishQuestion(outcome, row: row, index: index, item: item, draft: draft)
            updateNeedsYou(source.needsYouSnapshot)
        }
    }

    private func finishQuestion(_ outcome: NeedsYouAnswerOutcome, row: MenuBarNeedsYouSection.Row, index: Int, item: NeedsYouItem, draft: String) {
        let phase = Self.phase(for: outcome, item: item, draft: draft)
        if outcome == .accepted { questionDrafts[row.id] = nil }
        questionPhases[row.id] = phase
        announce(phase)
        if MenuBarQuestionState(phase: phase).isHeld { heldQuestions[row.id] = MenuBarHeldQuestion(row: row, index: index) }
    }

    /// Posted from here, not from the card: an accepted answer settles the item before the outcome returns, so the card
    /// can be recreated already settled and would never see a phase change.
    private func announce(_ phase: MenuBarQuestionState.Phase) {
        if let text = MenuBarQuestionState(phase: phase).announcement { AccessibilityNotification.Announcement(text).post() }
    }

    /// Drops what only lives until the popover closes: settled and unknown cards. Drafts and failures stay.
    func dropHeldQuestions() {
        guard !heldQuestions.isEmpty || questionPhases.values.contains(where: { MenuBarQuestionState(phase: $0).isHeld }) else { return }
        heldQuestions.removeAll()
        questionPhases = questionPhases.filter { !MenuBarQuestionState(phase: $0.value).isHeld }
        if let source = needsYouSource { updateNeedsYou(source.needsYouSnapshot) }
    }

    /// Lays the VM's question state over the rows built from the snapshot, restores held cards whose item left it, and forgets
    /// drafts and failures of items that are no longer pending.
    func applyQuestions(to rows: [MenuBarNeedsYouSection.Row], pendingIDs: Set<String>) -> [MenuBarNeedsYouSection.Row] {
        let kept = Set(heldQuestions.keys)
        // A submit in flight outlives its item leaving the snapshot: its draft must survive an unknown result.
        let inFlight = Set(questionPhases.compactMap { $0.value == .submitting ? $0.key : nil })
        for id in questionDrafts.keys where !pendingIDs.contains(id) && !kept.contains(id) && !inFlight.contains(id) { questionDrafts[id] = nil }
        for (id, phase) in questionPhases where !pendingIDs.contains(id) && !kept.contains(id) {
            if case .submitting = phase { continue }
            questionPhases[id] = nil
        }
        var result = rows.map { row -> MenuBarNeedsYouSection.Row in
            guard row.question != nil else { return row }
            var updated = row
            updated.question = MenuBarQuestionState(draft: questionDrafts[row.id] ?? "", phase: questionPhases[row.id] ?? .editing)
            return updated
        }
        let present = Set(result.map(\.id))
        for (id, held) in heldQuestions.sorted(by: { $0.value.index < $1.value.index }) where !present.contains(id) {
            var restored = held.row
            restored.question = MenuBarQuestionState(draft: questionDrafts[id] ?? "", phase: questionPhases[id] ?? .editing)
            result.insert(restored, at: min(held.index, result.count))
        }
        return result
    }

    /// The card's phase for an outcome. Pure; the draft is kept for everything but an accepted answer, and an unknown
    /// delivery never offers to send again.
    nonisolated static func phase(for outcome: NeedsYouAnswerOutcome, item: NeedsYouItem, draft: String) -> MenuBarQuestionState.Phase {
        let saved = draft.isEmpty ? [] : ["Your saved draft", draft]
        switch outcome {
        case .accepted:
            return .settled(title: "Answered", lines: [draft.trimmingCharacters(in: .whitespacesAndNewlines), item.settledNote], action: .none)
        case .alreadyAnswered(let answer, let owner, let timestamp, let truncated):
            let time = Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .shortened)
            return .settled(title: owner == .caller ? "Already answered by the caller" : "Answered in Harflow",
                            lines: [answer, (truncated ? "Answer excerpt · " : "") + time] + saved, action: .none)
        case .stale(let message):
            return .settled(title: nil, lines: [message] + saved, action: .open)
        case .changed:
            return .settled(title: nil, lines: [NeedsYouAnswerOutcome.changedMessage] + saved, action: .open)
        case .callerReturned(let message):
            return .settled(title: nil, lines: [message] + saved, action: .open)
        case .failed(let message, let code, _):
            return .failed(message: message, code: code)
        case .unknown:
            return .unknown
        case .approvalOutcome:
            return .settled(title: nil, lines: ["This request cannot be answered here."], action: .open)
        }
    }
}
