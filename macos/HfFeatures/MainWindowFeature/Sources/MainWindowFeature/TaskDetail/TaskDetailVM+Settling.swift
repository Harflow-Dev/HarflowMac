import HfRepository

// MARK: - Settling evidence

/// Qualification of one applied Changes read, independent of retained Changes presentation.
struct TaskSettlingReadEvidence: Equatable {
    let member: String
    let generation: UInt64
    let scope: EventObservationScope
}

extension EventObservationFrame {
    var qualifiesForSettlingNotice: Bool {
        history.currentness == .current && history.failure == nil && logState == .settling
    }
}

extension TaskDetailVM {
    var isSettling: Bool {
        guard !isStatusUnavailable, isMounted, chrome == .standalone, let task, task.status.isTerminal, !task.takenOver,
              leases[currentTaskID] != nil, changesReadMemberID == currentTaskID,
              let snapshot = useCase.snapshot(currentTaskID), snapshot.taskID == currentTaskID,
              snapshot.status == task.status, !snapshot.takenOver,
              let frame = observationFrames[currentTaskID], frame.taskID == currentTaskID,
              frame.qualifiesForSettlingNotice, let evidence = settlingReadEvidence,
              evidence.member == currentTaskID, evidence.generation == changesLifecycle.generation,
              evidence.scope == frame.scope, !changesLifecycle.capped else { return false }
        return true
    }

    func qualifySettlingRead(member: String, generation: UInt64, scope: EventObservationScope?, isSettling: Bool) {
        guard isSettling, generation == changesLifecycle.generation, !changesLifecycle.capped,
              let scope, let frame = observationFrames[member], frame.scope == scope,
              frame.taskID == member, frame.qualifiesForSettlingNotice else { return }
        settlingReadEvidence = .init(member: member, generation: generation, scope: scope)
    }
}
