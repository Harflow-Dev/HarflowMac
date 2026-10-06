//
//  TaskDetailVM+Actions.swift
//  MainWindowFeature
//
//  Cancel, Take over, and the message box's Send/Continue (`TaskDetailView.swift:95-99`,
//  `MessageBox`, `AppModel.swift:254-256`). Monitor piece 7: every action targets the
//  conversation's CURRENT member (`currentTaskID`), never `taskID` (which may be an older member —
//  Design point 6), and a successful Continue no longer navigates (Design point 7): the
//  conversation stays selected and its new turn appears once the listing refreshes.
//

import Foundation
import MonitorCore
import PbCommon
import PbUI

extension TaskDetailVM {

    /// Whether `dialogTaskID` — the task a confirmation dialog's OWN copy described, captured when
    /// it was published — is stale by the time the person confirms it (Codex review round 2,
    /// finding 1): the conversation "moved on" underneath the dialog (a follow-up resumed it) if
    /// `currentTaskID` no longer matches. Confirming a stale dialog must never silently retarget
    /// onto whatever the conversation's new current member happens to be, so this refuses instead
    /// and records why through the same durable `setOutcome` channel every other refusal uses — on
    /// `currentTaskID`, since that is whatever the person is looking at right now. Returns whether
    /// it refused, so the caller can bail out of its own confirm action.
    private func refuseIfConversationMovedOn(from dialogTaskID: String) -> Bool {
        guard currentTaskID != dialogTaskID else { return false }
        useCase.setOutcome(currentTaskID, "The conversation moved on — review and try again.")
        return true
    }

    /// Take over always opens Terminal.app — the Monitor's only take-over destination. Captures the
    /// dialog's own target (`dialogTaskID`) at the moment it is published, and the confirm action
    /// checks it against `currentTaskID` before acting (`refuseIfConversationMovedOn` — Codex review
    /// round 2, finding 1): if the conversation moved on while the dialog was open, this refuses
    /// rather than silently taking over whatever the new current member turned out to be.
    func didTapTakeover() {
        guard !isWorkflowBuilder, WorkflowNodePresentation.allowsTerminal(task) else { return }
        guard let task else { return }
        let dialogTaskID = currentTaskID
        let isRunning = task.status.isRunning
        let title = isRunning ? "Take over this task?" : "Continue this session in a terminal?"
        let buttonTitle = isRunning ? "Stop it and take over" : "Continue in terminal"
        var message = isRunning
        ? "The headless run is stopped first (with any sub-tasks), then the same conversation opens in Terminal.app. "
        : "The same conversation opens in Terminal.app. "
        message += "It runs under your own default permissions, not this task's \(task.freedom ?? "freedom") level. "
        + "While the terminal is open, polybridge refuses resumes of this session from anywhere else."
        publishDialog(title, description: message) {
            AlertAction(title: buttonTitle) { [weak self] in
                guard let self else { return }
                guard !refuseIfConversationMovedOn(from: dialogTaskID) else { return }
                useCase.beginTakeover(taskID: dialogTaskID)
            }
            AlertAction(title: "Cancel", role: .cancel)
        }
    }

    /// Cancel scope honesty (Review round 1 item 5 / round 2): the confirmation describes the REAL
    /// scope of cancelling the current task — `MonitorCore.Lineage.cancelScope(of:in:)`'s exact
    /// match of `tasks.py`'s cascade — and names any sub-task an EARLIER turn started that is still
    /// running but outside that scope, so it is never silently implied to be stopped too.
    ///
    /// Same staleness guard as `didTapTakeover()` (Codex review round 2, finding 1): `dialogTaskID`
    /// captures the task this dialog's own copy described, and the confirm action refuses rather
    /// than cancelling whatever the conversation's new current member is if it moved on first.
    func didTapCancel() {
        guard !isWorkflowBuilder, !WorkflowNodePresentation.isNativeControl(task) else { return }
        let dialogTaskID = currentTaskID
        var description = "polybridge stops the run and, best-effort, every live sub-task it started."
        let notCancelled = notCancelledByThisTitles()
        if !notCancelled.isEmpty {
            description += " Still running from earlier turns (not cancelled by this): \(notCancelled.joined(separator: ", "))."
        }
        publishDialog("Cancel this task?", description: description) {
            AlertAction(title: "Cancel task and its sub-tasks", role: .destructive) { [weak self] in
                guard let self else { return }
                guard !refuseIfConversationMovedOn(from: dialogTaskID) else { return }
                Task { [useCase] in try? await useCase.cancel(dialogTaskID) }
            }
        }
    }

    /// Titles of every still-running task reachable from an EARLIER conversation turn that
    /// cancelling the CURRENT task would not reach. "Reachable from" is the earlier turn's OWN
    /// cancel scope — the FULL descendant closure `cancelScope(of:)` computes (every level, not
    /// just a direct child; e.g. "earlier turn A → completed X → running Y" names Y even though it
    /// is A's grandchild, not A's own child — Codex review round 1, finding 5), unioned across every
    /// member but the current one, then minus `cancelScope(of: currentTaskID)`. A task reachable
    /// only via `root_task_id` (not `spawned_by`) still counts as in scope for whichever turn's
    /// cascade reaches it that way, so it is never listed here even though it "looks like" an
    /// earlier turn's own descendant (Review round 2).
    private func notCancelledByThisTitles() -> [String] {
        let currentScope = useCase.cancelScope(of: currentTaskID)
        var reachableFromEarlierTurns: Set<String> = []
        for member in conversationMembers where member.taskID != currentTaskID {
            reachableFromEarlierTurns.formUnion(useCase.cancelScope(of: member.taskID))
        }
        return reachableFromEarlierTurns.subtracting(currentScope)
            .sorted()
            .filter { useCase.task($0)?.status.isRunning == true }
            .map { useCase.title($0) }
    }

    /// Copies `resumeCommand` to the pasteboard through `routing`, then records the outcome
    /// through `TaskActionRepository.setOutcome` (the durable channel Cancel/Send/Resume already
    /// use) — never only this VM's `outcomeMessage`, which the next `recompute()` would overwrite.
    func didTapCopyResumeCommand() {
        guard let resumeCommand else { return }
        let succeeded = routing.copyToPasteboard(resumeCommand)
        let text = if !succeeded {
            "Couldn't copy to the clipboard."
        } else if task?.status.isRunning == true {
            "Copied. This task is still running — resuming it now would put two writers "
            + "on one conversation; prefer Take over."
        } else {
            "Copied resume command."
        }
        useCase.setOutcome(currentTaskID, text)
    }

    /// Copies the current run's task id, recording the outcome through the same durable channel as
    /// `didTapCopyResumeCommand()`.
    func didTapCopyTaskID() {
        let succeeded = routing.copyToPasteboard(currentTaskID)
        useCase.setOutcome(currentTaskID, succeeded ? "Copied task ID." : "Couldn't copy to the clipboard.")
    }

    var loadingHeader: TaskLoadingHeader? {
        guard let first = useCase.conversationMembers(of: taskID).first ?? useCase.task(taskID) else { return nil }
        return TaskLoadingHeader(title: useCase.title(first.taskID), repoName: Format.repoName(first.repoPath))
    }

    func didTapCopyRepoPath() {
        guard let path = task?.repoPath, !path.isEmpty else { return }
        let succeeded = routing.copyToPasteboard(path)
        useCase.setOutcome(currentTaskID, succeeded ? "Copied path." : "Couldn't copy to the clipboard.")
    }

    /// Send requires `liveInput && running && !takenOver`; Continue (resume) requires a terminal
    /// status plus a session (`TaskDetailView.swift:299-300`). When neither is eligible the
    /// composer is disabled with the copy of the specific `MessageBoxDisabledReason` (settled plan
    /// D7) — a taken-over running task no longer claims it "was not started with live input".
    func recomputeMessageBox(task: TaskInfo) {
        if isWorkflowBuilder {
            messageBoxModel = MessageBoxModel(canSend: task.status.isRunning, canContinue: task.status.isTerminal, isBusy: isBusy,
                                              label: "Message this task",
                                              hint: "Messages join the current turn when supported, or queue for the next builder turn",
                                              placeholder: "Ask for changes to this workflow…", buttonLabel: task.status.isRunning ? "Send" : "Continue")
            return
        }
        if WorkflowNodePresentation.blocksDirectMessages(task) {
            messageBoxModel = MessageBoxModel(canSend: false, canContinue: false, isBusy: isBusy,
                                              label: "Workflow-managed task", hint: "Answer workflow questions from the workflow run",
                                              placeholder: "The workflow controls this task until the run has settled", buttonLabel: "Send", isLocked: true)
            return
        }
        let canSend = task.liveInput && task.status.isRunning && !task.takenOver
        let canContinue = task.status.isTerminal && task.sessionID != nil
        let label = canSend ? "Message this task" : (canContinue ? "Continue this session" : "Messages")
        let hint = canSend
        ? "Queued; folded into the current turn or sent after it"
        : (canContinue ? "Continues the same agent session; the reply appears below as a new turn" : "")
        let disabledReason = MessageBoxDisabledReason.reason(for: task)
        let placeholder = if canSend {
            "Message this task while it runs…"
        } else if canContinue {
            "Send a follow-up — it continues this conversation"
        } else {
            disabledReason.text
        }
        messageBoxModel = MessageBoxModel(
            canSend: canSend, canContinue: canContinue, isBusy: isBusy,
            label: label, hint: hint, placeholder: placeholder, buttonLabel: canSend ? "Send" : "Continue",
            isLocked: !canSend && !canContinue && disabledReason.showsLock
        )
    }

    /// Trims the message, then dispatches Send or Continue. Returns `true` (so the caller clears its
    /// field immediately, regardless of the later outcome) for any eligible dispatch; `false` for a
    /// blank or ineligible submit, which keeps the text (`TaskDetailView.swift:336-345`).
    @discardableResult
    func submitMessage(_ text: String) -> Bool {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return false }
        guard let task else { return false }
        if isWorkflowBuilder {
            guard task.status.isRunning || task.status.isTerminal else { return false }
            let capturedUseCase = useCase
            let id = currentTaskID
            Task {
                do {
                    _ = try await capturedUseCase.send(id, text: message)
                } catch {
                    capturedUseCase.setOutcome(id, "Couldn't queue the builder message: \(error.localizedDescription)")
                }
            }
            return true
        }
        guard !WorkflowNodePresentation.blocksDirectMessages(task) else { return false }
        let canSend = task.liveInput && task.status.isRunning && !task.takenOver
        let canContinue = task.status.isTerminal && task.sessionID != nil
        if canSend {
            let capturedUseCase = useCase
            let id = currentTaskID
            Task { try? await capturedUseCase.send(id, text: message) }
            return true
        } else if canContinue {
            // Capture `useCase` strongly before awaiting, so a resume that outlives this VM (the
            // selection moved elsewhere) still lands. Continue no longer navigates (Design point 7):
            // the conversation stays selected, and the new turn appears once the listing refreshes
            // and this VM's own `tasksPublisher` sink picks up the new member.
            let capturedUseCase = useCase
            let id = currentTaskID
            Task {
                _ = try? await capturedUseCase.resume(id, text: message) { _ in }
            }
            return true
        }
        return false
    }
}
