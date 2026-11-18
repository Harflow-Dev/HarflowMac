import Foundation
import MonitorCore

// MARK: - WorkflowVM Goal

extension WorkflowVM {
    /// Opens the shared draft on the run's current goal. An open draft for the same run is kept.
    func beginGoalDraft(run: WorkflowRunModel) {
        guard run.canReviseGoal, selectedRun?.id == run.id else { return }
        if goalDraft?.runID == run.id { return }
        goalDraft = WorkflowGoalDraft(sessionID: UUID(), runID: run.id, expectedRevision: run.goalRevision, text: run.goal ?? "")
        goalRevisionError = nil
    }

    func updateGoalDraft(_ text: String) {
        guard var draft = goalDraft, draft.text != text else { return }
        draft.text = text
        goalDraft = draft
        if goalRevisionError != nil { goalRevisionError = nil }
    }

    func cancelGoalDraft() {
        if goalDraft != nil { goalDraft = nil }
        if goalRevisionError != nil { goalRevisionError = nil }
    }

    /// Closes the draft once the run shows the revision it was opened for with the same text (a save the poll saw first).
    func reconcileGoalDraft() {
        guard let draft = goalDraft, let run = selectedRun, run.id == draft.runID,
              run.goalRevision > draft.expectedRevision, run.goal == draft.text else { return }
        goalDraft = nil
    }

    func reviseGoal(_ goal: String, runID: String, expectedRevision: Int) {
        guard let run = selectedRun, run.id == runID, run.canReviseGoal, !isBusy else { return }
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, goal.utf8.count <= 65_536 else {
            reportGoalError("Goal must contain text and be at most 64 KiB of UTF-8 text.", draftOpen: goalDraft?.runID == runID)
            return
        }
        let session = goalDraft.flatMap { $0.runID == runID ? $0.sessionID : nil }
        goalRevisionError = nil
        perform { [weak self] in
            guard let self else { return }
            do {
                _ = try await builderCommand("revise-goal",
                                             options: ["--monitor", "--goal=\(goal)", "--expected-revision=\(expectedRevision)"],
                                             positionals: [runID])
                goalSaved(goal, runID: runID, session: session, expectedRevision: expectedRevision)
            } catch {
                goalSaveFailed(error, goal: goal, runID: runID, session: session, expectedRevision: expectedRevision)
            }
            await refresh()
        }
    }

    /// Shows a goal error in the form while a draft is open, and in the screen header otherwise, so it is never lost.
    private func reportGoalError(_ message: String, draftOpen: Bool) {
        if draftOpen { goalRevisionError = message } else { errorText = message }
    }

    /// Whether a save's result still belongs to what is on screen: the same run and, for a draft save, the same editing session.
    private func isCurrentGoalSave(runID: String, session: UUID?) -> Bool {
        guard selectedRun?.id == runID else { return false }
        return session == nil || goalDraft?.sessionID == session
    }

    private func goalSaved(_ goal: String, runID: String, session: UUID?, expectedRevision: Int) {
        guard session != nil, isCurrentGoalSave(runID: runID, session: session), var draft = goalDraft else { return }
        if draft.text == goal {
            goalDraft = nil
        } else {
            // Edits made while saving stay; they now build on the revision this save created.
            draft.expectedRevision = expectedRevision + 1
            goalDraft = draft
        }
    }

    private func goalSaveFailed(_ error: Error, goal: String, runID: String, session: UUID?, expectedRevision: Int) {
        guard isCurrentGoalSave(runID: runID, session: session) else { return }
        if let winner = (error as? ToolError)?.workflowInteractionWinner {
            // The latest edits are the draft worth keeping when the session is still open.
            retainInteractionOutcome(winner, draft: goalDraft?.text ?? goal, rootID: runID,
                                     goalRaceRevision: winner.action == "revise_goal" ? expectedRevision : nil)
            if session != nil { goalDraft = nil }
        } else {
            reportGoalError(Self.refusalMessage(error), draftOpen: session != nil)
        }
    }

    /// The engine's own message for a refusal, without the code suffix `ToolError.message` appends.
    private static func refusalMessage(_ error: Error) -> String {
        switch error as? ToolError {
        case .refused(_, let message), .structuredRefusal(_, let message, _): message
        default: message(error)
        }
    }
}
