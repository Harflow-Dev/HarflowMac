import Foundation
import HfCommon
import HfRepository
import MonitorCore

// MARK: - TaskDetailVM message submission

extension TaskDetailVM {
    func prepareMessagingSupport() {
        guard isMounted else { return }
        guard let context = try? useCase.messagingInvocationContext() else {
            messagingSupportRead?.cancel()
            messagingSupportRead = nil
            messagingSupportContext = nil
            messagingSupported = nil
            messageSendOutcome = nil
            return
        }
        let changed = messagingSupportContext != context
        if changed || messagingOutcomeTaskID != currentTaskID {
            messagingOutcomeTaskID = currentTaskID
            messageSendOutcome = useCase.messageAttempts()
.last(where: {
                guard $0.runtime == context.runtime, $0.taskID == currentTaskID else { return false }
                guard case .send = $0.operation else { return false }
                // Unsafe historical uncertainty remains a warning, never current acknowledgement.
                return $0.isUnconfirmed || useCase.isMessagingAttemptCurrent($0)
            })
.flatMap { WorkMessageOutcome.submission($0) }
            timelineModel.messageOutcome = messageCancellationOutcome ?? messageSendOutcome
        }
        guard changed else { return }
        messagingSupportRead?.cancel()
        messagingSupportContext = context
        messagingSupported = nil
        messagingSupportRead = Task { [weak self, useCase] in
            let supported = await useCase.messagingSupport(context: context)
            guard let self, isMounted, !Task.isCancelled, messagingSupportContext == context,
                  useCase.isMessagingContextCurrent(context) else { return }
            messagingSupported = supported
            if let task { recomputeMessageBox(task: task) }
        }
    }

    /// The completion owns only captured draft clearing, never a task identity or navigation.
    func submitMessage(_ text: String, now: Bool, completion: @escaping (Bool) -> Void) {
        submitMessage(text, now: now, acknowledging: nil, completion: completion)
    }

    private func submitMessage(_ text: String, now: Bool, acknowledging: UUID?, completion: @escaping (Bool) -> Void) {
        guard isMounted, !messageSendInFlight, !isBusy, messagingSupported == true,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let task = latestActionTask(), !task.takenOver,
              !(now && settledStandaloneMessagingTarget(task)) else { completion(false); return }
        let context: MessagingInvocationContext
        do { context = try useCase.messagingInvocationContext() } catch { completion(false); return }
        guard messagingSupportContext == context, useCase.isMessagingContextCurrent(context) else { completion(false); return }
        let id = currentTaskID
        if let previous = useCase.messageAttempts().last(where: {
            guard $0.runtime == context.runtime, $0.taskID == id, $0.isUnconfirmed else { return false }
            if case .send = $0.operation { return true }
            return false
        }), previous.id != acknowledging {
            publishDialog("Send this message again?",
                          description: "The earlier message may already have been accepted. Sending again may queue a duplicate.") {
                AlertAction(title: "Send again") { [weak self] in
                    guard let self, isMounted, currentTaskID == id, useCase.isMessagingContextCurrent(context) else { completion(false); return }
                    submitMessage(text, now: now, acknowledging: previous.id, completion: completion)
                }
                AlertAction(title: "Cancel", role: .cancel) { completion(false) }
            }
            return
        }
        launchMessageSubmission(text, now: now, acknowledging: acknowledging, context: context, completion: completion)
    }

    private func launchMessageSubmission(_ text: String, now: Bool, acknowledging: UUID?,
                                         context: MessagingInvocationContext, completion: @escaping (Bool) -> Void) {
        let id = currentTaskID
        // Synchronous admission precedes Task creation, closing the two-click scheduling gap.
        messageSendInFlight = true
        messageCancellationOutcome = nil
        messageOutcomeFocus = nil
        let epoch = UUID()
        messageSendEpoch = epoch
        let generation = continuationSession.generation
        let capturedUseCase = useCase
        if let task { prepareContinuation(task: task); recomputeMessageBox(task: task) }
        Task { [weak self] in
            guard let self else { completion(false); return }
            defer {
                if messageSendEpoch == epoch {
                    messageSendInFlight = false
                    if let task = self.task { prepareContinuation(task: task); recomputeMessageBox(task: task) }
                }
            }
            guard isMounted, currentTaskID == id, continuationSession.generation == generation else {
                completion(false); return
            }
            do {
                let attempt = try await capturedUseCase.submitTypedMessage(id, text: text, now: now,
                                                                          acknowledgingUnconfirmed: acknowledging, context: context)
                guard attempt.taskID == id, attempt.operation == .send(now: now),
                      capturedUseCase.isMessagingAttemptCurrent(attempt),
                      case .send(let result) = attempt.outcome else { completion(false); return }
                // Draft ownership is independent of mount/navigation. Clear the original revision
                // on acceptance even after teardown; presentation below still requires this mount.
                let accepted = if case .receipt(let receipt) = result {
                    switch receipt.status {
                    case .queued, .delivering, .delivered, .undeliverable: true
                    case .cancelled, .unknown: false
                    }
                } else { false }
                completion(accepted)
                guard isMounted, currentTaskID == id, messageSendEpoch == epoch,
                      continuationSession.generation == generation else { return }
                messageSendOutcome = WorkMessageOutcome.submission(attempt)
                timelineModel.messageOutcome = messageSendOutcome
                applyMessageResult(result, source: id, context: context)
            } catch {
                guard isMounted, currentTaskID == id, messageSendEpoch == epoch,
                      continuationSession.generation == generation,
                      capturedUseCase.isMessagingContextCurrent(context) else { completion(false); return }
                messageSendOutcome = error.localizedDescription
                timelineModel.messageOutcome = messageSendOutcome
                capturedUseCase.setOutcome(id, error.localizedDescription)
                completion(false)
            }
        }
    }

    private func applyMessageResult(_ result: MessagingOutcome<MessagingSendReceipt>, source id: String,
                                    context: MessagingInvocationContext) {
        switch result {
        case .receipt(let receipt):
            switch receipt.status {
            case .queued, .delivering, .delivered, .undeliverable:
                rememberMessageResult(receipt.raw)
                useCase.setOutcome(id, WorkMessageOutcome.describe(receipt.raw))
                if receipt.status == .delivering, let successor = receipt.successorTaskID {
                    openMessagingSuccessor(successor, source: id, context: context)
                }
            case .cancelled, .unknown:
                useCase.setOutcome(id, "Sending could not be confirmed. The message may already have been queued.")
            }
        case .refused(let error):
            useCase.setOutcome(id, error.message)
            if error.kind == .superseded, let successor = error.successorTaskID,
               TaskPendingLaunchWire.isFullID(successor) {
                publishDialog("Open the successor task?", description: error.message) {
                    AlertAction(title: "Open task \(successor)") { [weak self] in
                        self?.openMessagingSuccessor(successor, source: id, context: context)
                    }
                    AlertAction(title: "Cancel", role: .cancel)
                }
            }
        case .unconfirmed:
            useCase.setOutcome(id, "Sending could not be confirmed. The message may already have been queued.")
        case .messagingUnsupported:
            messagingSupported = false
            if let task { recomputeMessageBox(task: task) }
            useCase.setOutcome(id, "This engine does not support queued messages.")
        case .notDispatched:
            useCase.setOutcome(id, "The message was not sent. Your draft has been kept.")
        }
    }

    private func openMessagingSuccessor(_ successor: String, source: String, context: MessagingInvocationContext) {
        guard isMounted, currentTaskID == source, useCase.isMessagingContextCurrent(context),
              TaskPendingLaunchWire.isFullID(successor), successor != source,
              useCase.task(successor)?.taskID == successor else { return }
        // The owner finished its public refresh before returning this structured successor.
        // Existing routing consumes only the now-listed task; prose never supplies an identity.
        routing.selectTask(successor)
    }
}
