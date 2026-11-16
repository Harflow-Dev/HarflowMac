import Foundation
import MonitorCore

// MARK: - MessagingSubmissionAttempt

/// App-session invocation evidence. Ledger refreshes never rewrite or identify an attempt.
public struct MessagingSubmissionAttempt: Equatable, Sendable, Identifiable {
    public enum Operation: Equatable, Sendable {
        case send(now: Bool)
        case cancel(messageID: String)
    }

    public enum Outcome: Equatable, Sendable {
        case sending
        case send(MessagingOutcome<MessagingSendReceipt>)
        case cancel(MessagingOutcome<MessagingCancelReceipt>)
    }

    public let id: UUID
    public let runtime: QualificationRuntimeToken
    public let runtimeEpoch: UUID
    public let taskID: String
    public let operation: Operation
    public let outcome: Outcome

    public var isUnconfirmed: Bool {
        switch outcome {
        case .send(.unconfirmed), .cancel(.unconfirmed), .sending: true
        default: false
        }
    }
}

// MARK: - MessagingAdmissionError

/// Refusals before any mutation. Capacity never evicts unresolved evidence.
public enum MessagingAdmissionError: Error, Equatable, Sendable {
    case busy, capacity, invalidIdentity, runtimeChanged
    case previousUnconfirmed(UUID)
}
