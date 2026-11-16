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
        case .send(.receipt(let receipt)):
            switch receipt.status {
            case .cancelled, .unknown: true
            case .queued, .delivering, .delivered, .undeliverable: false
            }
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

// MARK: - MessagingInvocationContext

/// Click-time messaging authority. Runtime tokens alone cannot distinguish A→B→A.
public struct MessagingInvocationContext: Equatable, Sendable {
    public let runtime: QualificationRuntimeToken
    public let runtimeEpoch: UUID
}
