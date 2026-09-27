//
//  TaskDetailVM+Actions.swift
//  MainWindowFeature
//
//  Cancel, Take over, and the message box's Send/Continue (`TaskDetailView.swift:95-99`,
//  `MessageBox`, `AppModel.swift:254-256`).
//

import Foundation
import MonitorCore
import PbCommon

extension TaskDetailVM {

    /// Take over always opens Terminal.app — the Monitor's only take-over destination.
    func didTapTakeover() {
        guard let task else { return }
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
                useCase.beginTakeover(taskID: taskID)
            }
            AlertAction(title: "Cancel", role: .cancel)
        }
    }

    func didTapCancel() {
        publishDialog("Cancel this task?", description: "polybridge stops the run and, best-effort, every live sub-task it started.") {
            AlertAction(title: "Cancel task and its sub-tasks", role: .destructive) { [taskID, useCase] in
                Task { try? await useCase.cancel(taskID) }
            }
        }
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
        useCase.setOutcome(taskID, text)
    }

    /// Send requires `liveInput && running && !takenOver`; Continue (resume) requires a terminal
    /// status plus a session (`TaskDetailView.swift:299-300`).
    func recomputeMessageBox(task: TaskInfo) {
        let canSend = task.liveInput && task.status.isRunning && !task.takenOver
        let canContinue = task.status.isTerminal && task.sessionID != nil
        let label = canSend ? "Message this task" : (canContinue ? "Continue this session" : "Messages")
        let hint = canSend ? "Queued; folded into the current turn or sent after it" : (canContinue ? "Runs `resume` through polybridge" : "")
        let placeholder = if canSend {
            "Message this task while it runs…"
        } else if canContinue {
            "Send a follow-up — it resumes the session as a new task"
        } else if task.status.isRunning {
            "This task was not started with live input, so it cannot take messages while it runs."
        } else {
            "This task has no session to continue."
        }
        messageBoxModel = MessageBoxModel(
            canSend: canSend, canContinue: canContinue, isBusy: isBusy,
            label: label, hint: hint, placeholder: placeholder, buttonLabel: canSend ? "Send" : "Continue"
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
        let canSend = task.liveInput && task.status.isRunning && !task.takenOver
        let canContinue = task.status.isTerminal && task.sessionID != nil
        if canSend {
            let capturedUseCase = useCase
            Task { try? await capturedUseCase.send(taskID, text: message) }
            return true
        } else if canContinue {
            // Capture `useCase`/`routing` strongly before awaiting, so a resume that outlives this
            // VM (the selection moved elsewhere) still routes to the new task (decision 3/F4-17).
            // Routing happens from `onResumed`, fired the instant the new id comes back — matching
            // the original's immediate selection (`AppModel.swift:291-299`), ahead of this task's own
            // busy/outcome/refresh bookkeeping (item 4).
            let capturedUseCase = useCase
            let capturedRouting = routing
            let id = taskID
            Task {
                // Awaited, like the original's `await MainActor.run`: the selection has moved before
                // busy is released and the refreshes start.
                _ = try? await capturedUseCase.resume(id, text: message) { newID in
                    await MainActor.run { capturedRouting.selectTask(newID) }
                }
            }
            return true
        }
        return false
    }
}
