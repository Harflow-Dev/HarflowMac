import Foundation
import HfRepository
import MonitorCore

// MARK: - PendingLaunchStopEvidence

/// What the screen knows about one Stop attempt. It carries no runtime token and no environment: the runtime
/// match happens where the owner's attempts are read, and only this value crosses into the projection.
struct PendingLaunchStopEvidence: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// The engine call is in flight.
        case sending
        /// Nothing was dispatched because the launch changed (it became a task, or its support changed).
        case preflightChanged
        /// Nothing was dispatched for another local reason.
        case notSent
        /// The engine proved the launch never started.
        case didNotStart
        /// The engine accepted the request. This is not proof that anything stopped.
        case requested
        /// The command ran and its outcome cannot be established.
        case uncertain
        /// The engine refused; `reason` is its message, already normalized for display.
        case refused(reason: String?)

        /// An accepted, uncertain or refused attempt, or a proven did-not-start: the phases that show an outcome card.
        var isResolvedOutcome: Bool {
            switch self {
            case .requested, .uncertain, .refused, .didNotStart: true
            case .sending, .preflightChanged, .notSent: false
            }
        }
    }

    let attemptID: UUID
    let taskID: String
    let generation: String
    let phase: Phase

    /// Mirrors the owner's own rule for what blocks another Stop (`PendingLaunchStopOwner.isUnsafe`): everything
    /// except "not sent" and "preflight changed".
    var isUnsafe: Bool {
        switch phase {
        case .notSent, .preflightChanged: false
        default: true
        }
    }

    /// True when the attempt leaves the launch's state unconfirmed (accepted, or outcome unknown).
    var isUnconfirmed: Bool { phase == .requested || phase == .uncertain }

    static let reasonLimit = 1024

    init(attemptID: UUID, taskID: String, generation: String, phase: Phase) {
        self.attemptID = attemptID
        self.taskID = taskID
        self.generation = generation
        self.phase = phase
    }

    /// Total classification. Anything not positively understood is treated as unsafe and unknown, never upgraded.
    init(_ attempt: PendingLaunchStopAttempt) {
        self.init(attemptID: attempt.id, taskID: attempt.confirmation.taskID, generation: attempt.confirmation.generation,
                  phase: Self.phase(of: attempt))
    }

    private static func phase(of attempt: PendingLaunchStopAttempt) -> Phase {
        if attempt.isExecuting { return .sending }
        // Every preflight failure is set before the engine command is dispatched, so "not sent" is truthful.
        if let failure = attempt.preflightFailure {
            switch failure {
            case .changed, .recorded: return .preflightChanged
            default: return .notSent
            }
        }
        switch attempt.outcome {
        case .notDispatched: return .notSent
        case .accepted(let receipt): return receipt.targetIsProvenNotStarted ? .didNotStart : .requested
        case .uncertain: return .uncertain
        case .engineError(_, let error): return .refused(reason: reason(from: error.message))
        // Not executing, no failure and no outcome cannot happen (`finishStop` always sets one). Conservatively
        // unsafe and unknown.
        case nil: return .uncertain
        }
    }

    /// The engine message for display: whitespace runs collapsed and trimmed, capped, then escaped. Nil when blank.
    static func reason(from message: String) -> String? {
        var collapsed = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count > reasonLimit { collapsed = String(collapsed.prefix(reasonLimit)) + "…" }
        return TaskChangesDisplayText.diffSafe(collapsed)
    }
}

// MARK: - PendingLaunchStopProjection

/// The selected ID's Stop attempts, for the current runtime only.
struct PendingLaunchStopProjection: Equatable, Sendable {
    /// The most recent attempt for the ID.
    var latest: PendingLaunchStopEvidence
    /// Generations an earlier attempt left unsafe (sending, requested, did not start, uncertain, refused).
    var unsafeGenerations: Set<String>
    /// Generations with a requested or uncertain attempt.
    var unconfirmedGenerations: Set<String>

    init?(_ attempts: [PendingLaunchStopEvidence], taskID: String) {
        let matching = attempts.filter { $0.taskID == taskID }
        guard let latest = matching.last else { return nil }
        self.latest = latest
        self.unsafeGenerations = Set(matching.filter(\.isUnsafe).map(\.generation))
        self.unconfirmedGenerations = Set(matching.filter(\.isUnconfirmed).map(\.generation))
    }

    var hasUnconfirmed: Bool { !unconfirmedGenerations.isEmpty }
}
