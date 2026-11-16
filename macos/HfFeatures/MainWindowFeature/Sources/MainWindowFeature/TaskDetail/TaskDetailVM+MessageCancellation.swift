import Foundation
import HfRepository
import MonitorCore

// MARK: - TaskDetailVM message cancellation

extension TaskDetailVM {
    func cancelQueuedMessage(_ messageID: String) {
        guard isMounted, latestActionTask() != nil, !isBusy,
              timelineModel.workMessages.contains(where: { $0.id == messageID && $0.canCancel }) else { return }
        let context: MessagingInvocationContext
        do {
            context = try useCase.messagingInvocationContext()
        } catch {
            messageCancellationOutcome = "Cancellation was not sent."
            updateMessageCancellationPresentation()
            return
        }
        let id = currentTaskID
        let epoch = UUID()
        messageCancellationEpoch = epoch
        messageOutcomeFocus = nil
        let capturedUseCase = useCase
        let runtime = useCase.continuationRuntime()
        let generation = continuationSession.generation
        Task { [weak self] in
            guard let self, isMounted, currentTaskID == id, messageCancellationEpoch == epoch,
                  capturedUseCase.continuationRuntime() == runtime, continuationSession.generation == generation else { return }
            do {
                let attempt = try await capturedUseCase.cancelMessage(id, messageID: messageID, context: context)
                guard isMounted, currentTaskID == id, messageCancellationEpoch == epoch,
                      capturedUseCase.continuationRuntime() == runtime, continuationSession.generation == generation,
                      attempt.taskID == id, attempt.operation == .cancel(messageID: messageID),
                      capturedUseCase.isMessagingAttemptCurrent(attempt) else { return }
                messageCancellationAttempt = attempt
                messageCancellationOutcome = WorkMessageOutcome.cancellation(attempt, messageID: messageID)
                if case .cancel(.receipt(let receipt)) = attempt.outcome,
                   receipt.messageID == messageID, receipt.status == .cancelled {
                    messageOutcomeFocus = attempt.id
                }
                updateMessageCancellationPresentation()
            } catch {
                guard isMounted, currentTaskID == id, messageCancellationEpoch == epoch,
                      capturedUseCase.continuationRuntime() == runtime, continuationSession.generation == generation else { return }
                messageCancellationOutcome = "Couldn't cancel the message: \(error.localizedDescription)"
                updateMessageCancellationPresentation()
            }
        }
    }

    /// Consume before attempting native focus: a reused tail must never replay this action.
    func consumeMessageOutcomeFocus(_ token: UUID) -> Bool {
        guard messageOutcomeFocus == token else { return false }
        messageOutcomeFocus = nil
        timelineModel.messageOutcomeFocus = nil
        guard isMounted, let attempt = messageCancellationAttempt,
              attempt.id == token, attempt.taskID == currentTaskID,
              useCase.isMessagingAttemptCurrent(attempt) else { return false }
        return true
    }

    func reconcileMessageCancellation(taskID: String) {
        let changed = currentTaskID != taskID
        let stale = messageCancellationAttempt.map { !useCase.isMessagingAttemptCurrent($0) } ?? false
        guard changed || stale else { return }
        messageCancellationEpoch = UUID()
        messageCancellationAttempt = nil
        messageCancellationOutcome = nil
        messageOutcomeFocus = nil
    }

    func applyingConfirmedCancellation(_ bubbles: [WorkMessageBubble]) -> [WorkMessageBubble] {
        guard let attempt = messageCancellationAttempt, attempt.taskID == currentTaskID,
              useCase.isMessagingAttemptCurrent(attempt),
              case .cancel(.receipt(let receipt)) = attempt.outcome, receipt.status == .cancelled,
              attempt.operation == .cancel(messageID: receipt.messageID) else { return bubbles }
        return bubbles.filter { $0.id != receipt.messageID }
    }

    private func updateMessageCancellationPresentation() {
        timelineModel.workMessages = applyingConfirmedCancellation(timelineModel.workMessages)
        timelineModel.messageOutcome = messageCancellationOutcome
        timelineModel.messageOutcomeFocus = messageOutcomeFocus
        timelineModel.consumeMessageOutcomeFocus = { [weak self] token in self?.consumeMessageOutcomeFocus(token) ?? false }
    }
}
