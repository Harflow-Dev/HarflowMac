import Combine
import Foundation
import MonitorCore

// MARK: - TaskActionRepositoryImpl messaging

extension TaskActionRepositoryImpl {
    /// Inline invalidation fences A→B→A without deleting prior invocation evidence.
    public func bindMessagingRuntimeChanges(_ publisher: AnyPublisher<ManagedRuntimeState, Never>) {
        messagingRuntimeSubscription = publisher.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            messagingLock.withLock { messagingEpoch = UUID() }
        }
    }

    public func isMessagingContextCurrent(_ context: MessagingInvocationContext) -> Bool {
        guard case .success(let client) = toolEnvironment.ctl(),
              QualificationRuntimeToken(client: client) == context.runtime else { return false }
        return messagingLock.withLock { messagingEpoch == context.runtimeEpoch }
    }

    public func isMessagingAttemptCurrent(_ attempt: MessagingSubmissionAttempt) -> Bool {
        guard case .success(let client) = toolEnvironment.ctl(),
              QualificationRuntimeToken(client: client) == attempt.runtime else { return false }
        return messagingLock.withLock {
            messagingEpoch == attempt.runtimeEpoch && messagingAttempts.contains(attempt)
        }
    }

    public func messageAttempts() -> [MessagingSubmissionAttempt] {
        messagingLock.withLock { messagingAttempts }
    }

    public func submitMessage(_ taskID: String, text: String, now: Bool,
                              acknowledgingUnconfirmed: UUID?) async throws -> MessagingSubmissionAttempt {
        try await submitMessage(taskID, text: text, now: now, acknowledgingUnconfirmed: acknowledgingUnconfirmed,
                                context: messagingInvocationContext())
    }

    public func submitMessage(_ taskID: String, text: String, now: Bool,
                              acknowledgingUnconfirmed: UUID?, context: MessagingInvocationContext) async throws -> MessagingSubmissionAttempt {
        let (attempt, client) = try beginMessaging(taskID, operation: .send(now: now), acknowledging: acknowledgingUnconfirmed,
                                                 invocationContext: context)
        defer { endBusy(taskID) }
        let result = await client.sendMessage(taskID, text: text, now: now)
        let completed = finishMessaging(attempt, outcome: .send(result))
        await refreshMessaging(completed)
        return completed
    }

    public func messagingInvocationContext() throws -> MessagingInvocationContext {
        let epoch = messagingLock.withLock { messagingEpoch }
        let client = try toolEnvironment.ctl().get()
        let runtime = QualificationRuntimeToken(client: client)
        return try messagingLock.withLock {
            guard messagingEpoch == epoch else { throw MessagingAdmissionError.runtimeChanged }
            return MessagingInvocationContext(runtime: runtime, runtimeEpoch: epoch)
        }
    }

    public func cancelQueuedMessage(_ taskID: String, messageID: String) async throws -> MessagingSubmissionAttempt {
        try await cancelQueuedMessage(taskID, messageID: messageID, context: messagingInvocationContext())
    }

    public func cancelQueuedMessage(_ taskID: String, messageID: String,
                                    context: MessagingInvocationContext) async throws -> MessagingSubmissionAttempt {
        guard Self.messagingID(messageID) else { throw MessagingAdmissionError.invalidIdentity }
        let (attempt, client) = try beginMessaging(taskID, operation: .cancel(messageID: messageID), acknowledging: nil,
                                                 invocationContext: context)
        defer { endBusy(taskID) }
        let result = await client.cancelQueuedMessage(taskID, messageID: messageID)
        let completed = finishMessaging(attempt, outcome: .cancel(result))
        await refreshMessaging(completed)
        return completed
    }

    private static func messagingID(_ value: String) -> Bool {
        value.count == 32 && value.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }

    private static func messagingTaskID(_ value: String) -> Bool {
        // Same bounded public identifier grammar as the engine. The caller supplies an observed
        // full identity; this owner never resolves prefixes, folds case or rewrites the value.
        TaskPendingLaunchWire.isFullID(value)
    }

    private func beginMessaging(_ taskID: String, operation: MessagingSubmissionAttempt.Operation,
                                acknowledging: UUID?, invocationContext: MessagingInvocationContext? = nil
    ) throws -> (MessagingSubmissionAttempt, CtlClient) {
        guard Self.messagingTaskID(taskID) else { throw MessagingAdmissionError.invalidIdentity }
        guard tryBeginBusy(taskID) else { throw MessagingAdmissionError.busy }
        do {
            let capturedEpoch = messagingLock.withLock { messagingEpoch }
            var client = try toolEnvironment.ctl().get()
            let runtime = QualificationRuntimeToken(client: client)
            // Runtime bindings are retained privately and never logged. Oversized bindings refuse
            // admission before reserving a mutation, rather than retaining unbounded environments.
            let bindingBytes = runtime.environment.reduce(runtime.executable.utf8.count) { $0 + $1.key.utf8.count + $1.value.utf8.count }
            guard bindingBytes <= 65536 else { throw MessagingAdmissionError.capacity }
            let attempt = try messagingLock.withLock {
                guard messagingEpoch == capturedEpoch else { throw MessagingAdmissionError.runtimeChanged }
                if let context = invocationContext {
                    guard context.runtimeEpoch == capturedEpoch, context.runtime == runtime else { throw MessagingAdmissionError.runtimeChanged }
                }
                guard messagingAttempts.count < 256,
                      messagingCosts.values.reduce(0, +) <= 16 * 1024 * 1024 - Self.messagingReservation else {
                    throw MessagingAdmissionError.capacity
                }
                if let previous = messagingAttempts.last(where: {
                    $0.runtime == runtime && $0.taskID == taskID && Self.sameMessagingOperation($0.operation, operation) && $0.isUnconfirmed
                }), previous.id != acknowledging {
                    throw MessagingAdmissionError.previousUnconfirmed(previous.id)
                }
                let value = MessagingSubmissionAttempt(id: UUID(), runtime: runtime, runtimeEpoch: capturedEpoch,
                                                       taskID: taskID, operation: operation, outcome: .sending)
                messagingAttempts.append(value)
                messagingCosts[value.id] = Self.messagingReservation
                return value
            }
            let existingGuard = client.operationIsCurrent
            client.operationIsCurrent = { [weak self] in
                guard let self, existingGuard(), messagingLock.withLock({ messagingEpoch == capturedEpoch }),
                      case .success(let current) = toolEnvironment.ctl() else { return false }
                return QualificationRuntimeToken(client: current) == runtime
            }
            return (attempt, client)
        } catch {
            endBusy(taskID)
            throw error
        }
    }

    private static func sameMessagingOperation(_ lhs: MessagingSubmissionAttempt.Operation,
                                               _ rhs: MessagingSubmissionAttempt.Operation) -> Bool {
        switch (lhs, rhs) {
        case (.send, .send): true
        case (.cancel(let first), .cancel(let second)): first == second
        default: false
        }
    }

    private static let messagingReservation = 1 << 20

    private func finishMessaging(_ attempt: MessagingSubmissionAttempt,
                                 outcome: MessagingSubmissionAttempt.Outcome) -> MessagingSubmissionAttempt {
        // Conservatively charge a diagnostic serialization plus the captured binding. Nothing is
        // logged. An oversized result stays unresolved and cannot become cancellation evidence.
        let cost = String(reflecting: outcome).utf8.count
            + attempt.runtime.environment.reduce(attempt.runtime.executable.utf8.count) { $0 + $1.key.utf8.count + $1.value.utf8.count }
            + 4096
        let bounded: MessagingSubmissionAttempt.Outcome = if cost > Self.messagingReservation {
            switch attempt.operation {
            case .send: .send(.unconfirmed(.outputTooLarge(bytes: cost)))
            case .cancel: .cancel(.unconfirmed(.outputTooLarge(bytes: cost)))
            }
        } else { outcome }
        let completed = MessagingSubmissionAttempt(id: attempt.id, runtime: attempt.runtime, runtimeEpoch: attempt.runtimeEpoch,
                                                   taskID: attempt.taskID, operation: attempt.operation, outcome: bounded)
        messagingLock.withLock {
            if let index = messagingAttempts.firstIndex(where: { $0.id == attempt.id }) { messagingAttempts[index] = completed }
            messagingCosts[attempt.id] = min(cost, Self.messagingReservation)
        }
        return completed
    }

    private func refreshMessaging(_ attempt: MessagingSubmissionAttempt) async {
        // An old runtime's command result remains attempt evidence, never current-task state.
        guard messagingLock.withLock({ messagingEpoch == attempt.runtimeEpoch }),
              case .success(let current) = toolEnvironment.ctl(),
              QualificationRuntimeToken(client: current) == attempt.runtime else { return }
        await snapshotRepository.refresh(attempt.taskID)
        guard messagingLock.withLock({ messagingEpoch == attempt.runtimeEpoch }) else { return }
        await taskListRepository.refresh()
    }
}
