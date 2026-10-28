import Foundation
import HfCommon
import MonitorCore

// MARK: - ParallelVM actions and messages

extension ParallelVM {
    func didTapCancelAll() {
        guard canCancelAll else { return }
        publishDialog("Cancel every running task in this group?") {
            AlertAction(title: "Cancel all", role: .destructive) { [weak self] in
                guard let self else { return }
                let ids = useCase.runningInSubtrees(of: memberIDs)
                Task { [useCase] in await useCase.cancelAll(ids) }
            }
        }
    }

    @discardableResult
    func submitMessage(_ text: String, conversationID: String, now: Bool) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let task = messageTarget(conversationID: conversationID) else { return false }
        let id = task.taskID
        messageDispatches.insert(id)
        recompute()
        let capturedUseCase = useCase
        Task { [weak self] in
            defer {
                self?.messageDispatches.remove(id)
                if self?.didSubscribe == true { self?.recompute() }
            }
            do {
                try await capturedUseCase.sendMessage(id, text: text, now: now)
            } catch {
                capturedUseCase.setOutcome(id, "Couldn't send the message: \((error as? ToolError)?.message ?? error.localizedDescription)")
            }
        }
        return true
    }

    func cancelMessage(_ messageID: String, conversationID: String) {
        guard let task = messageTarget(conversationID: conversationID, allowTakenOver: true) else { return }
        let id = task.taskID
        messageDispatches.insert(id)
        recompute()
        let capturedUseCase = useCase
        Task { [weak self] in
            defer {
                self?.messageDispatches.remove(id)
                if self?.didSubscribe == true { self?.recompute() }
            }
            do {
                try await capturedUseCase.cancelMessage(id, messageID: messageID)
            } catch {
                capturedUseCase.setOutcome(id, "Couldn't cancel the message: \((error as? ToolError)?.message ?? error.localizedDescription)")
            }
        }
    }

    private func messageTarget(conversationID: String, allowTakenOver: Bool = false) -> TaskInfo? {
        guard didSubscribe, let conversation = conversationByID[conversationID] else { return nil }
        let current = WorkflowNodePresentation.merged(latestSnapshots[conversation.current.taskID], with: conversation.current)
        guard allowTakenOver || !current.takenOver, !latestBusy.contains(current.taskID),
              !messageDispatches.contains(current.taskID) else { return nil }
        return current
    }
}
