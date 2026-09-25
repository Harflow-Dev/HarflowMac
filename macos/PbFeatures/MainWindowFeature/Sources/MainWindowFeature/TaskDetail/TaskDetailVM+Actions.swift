//
//  TaskDetailVM+Actions.swift
//  MainWindowFeature
//
//  Cancel and the message box's Send/Continue (`TaskDetailView.swift:95-99`, `MessageBox`,
//  `AppModel.swift:254-256`).
//

import Foundation
import MonitorCore
import PbCommon

extension TaskDetailVM {
    
    func didTapCancel() {
        publishDialog("Cancel this task?", description: "polybridge stops the run and, best-effort, every live sub-task it started.") {
            AlertAction(title: "Cancel task and its sub-tasks", role: .destructive) { [taskID, useCase] in
                Task { try? await useCase.cancel(taskID) }
            }
        }
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
