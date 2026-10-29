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
import HfCommon
import HfUI
import MonitorCore

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
        let buttonTitle = isRunning ? "Take over in terminal" : "Open in terminal"
        var message = isRunning
        ? "The headless run is stopped first (with any sub-tasks), then the same conversation opens in Terminal.app. "
        : "The same conversation opens in Terminal.app. "
        let requestedAccess = task.freedom.map { " (\(AccessLabel.text(freedom: $0)))" } ?? ""
        message += "It runs under your own default permissions, not this task's access level\(requestedAccess). "
        + "While the terminal is open, harflow refuses resumes of this session from anywhere else."
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
        var description = "harflow stops the run and, best-effort, every live sub-task it started."
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
            + "on one conversation; prefer Take over in terminal."
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

    /// The engine owns authorization; a non-live task can still queue a follow-up.
    func recomputeMessageBox(task: TaskInfo) {
        let eligible = !task.takenOver
        messageBoxModel = MessageBoxModel(
            canSend: eligible, canContinue: false, isBusy: isBusy,
            label: isWorkflowBuilder ? "Message the workflow builder" : "Message this task",
            hint: "Send queues; Send now requests immediate delivery when safe",
            placeholder: eligible ? "Queue a message…" : MessageBoxDisabledReason.takenOver.text,
            buttonLabel: "Send", isLocked: !eligible
        )
    }

    @discardableResult
    func submitMessage(_ text: String) -> Bool {
        dispatchMessage(text, now: false)
    }

    @discardableResult
    func submitMessageNow(_ text: String) -> Bool {
        dispatchMessage(text, now: true)
    }

    private func dispatchMessage(_ text: String, now: Bool) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let task, !task.takenOver, !isBusy else { return false }
        let capturedUseCase = useCase
        let id = currentTaskID
        // The queue path must not capture `self`: Continue stays in flight after the view model
        // is released. Send now records a refusal on the view model only while it is still alive.
        if now {
            Task { [weak self] in
                do {
                    let result = try await capturedUseCase.sendNow(id, text: text)
                    self?.rememberMessageResult(result)
                } catch {
                    capturedUseCase.setOutcome(id, "Couldn't send the message: \(error.localizedDescription)")
                }
            }
        } else {
            Task {
                do {
                    _ = try await capturedUseCase.send(id, text: text)
                } catch {
                    capturedUseCase.setOutcome(id, "Couldn't send the message: \(error.localizedDescription)")
                }
            }
        }
        return true
    }

    func rememberMessageResult(_ result: [String: JSONValue]) {
        guard let id = result["message_id"]?.stringValue, let note = WorkMessageBubble.refusalNote(in: result) else { return }
        messageNotes[id] = note
        timelineModel.workMessages = WorkMessageBubble.applying(timelineModel.workMessages, notes: messageNotes)
    }

    func cancelQueuedMessage(_ messageID: String) {
        let capturedUseCase = useCase
        let id = currentTaskID
        Task {
            do {
                try await capturedUseCase.cancelMessage(id, messageID: messageID)
            } catch {
                capturedUseCase.setOutcome(id, "Couldn't cancel the message: \(error.localizedDescription)")
            }
        }
    }
}
