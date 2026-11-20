import Foundation
import MonitorCore

// MARK: - WorkflowSteeringRepositoryImpl admission and reconciliation

extension WorkflowSteeringRepositoryImpl {
    func admitLocked(_ attempt: WorkflowSteeringAttempt, observation: WorkflowSteeringObservation) throws {
        guard retained.count < Self.maximumAttempts, retainedBytes <= Self.maximumBytes - Self.invocationReservation else {
            throw WorkflowSteeringAdmissionError.capacity
        }
        let previous = retained.filter {
            $0.request.status.rootID == attempt.request.status.rootID && $0.runtime.context.expectedStateRoot == attempt.runtime.context.expectedStateRoot
        }
        guard !previous.contains(where: { $0.outcome == nil }) else { throw WorkflowSteeringAdmissionError.busy }
        for old in previous {
            // A read begun before invocation settlement cannot qualify any subsequent action.
            guard let settled = old.settledReadOrdinal, observation.readOrdinal > settled else {
                throw WorkflowSteeringAdmissionError.staleObservation
            }
            if old.isIndeterminate {
                // A separately authorized Dismiss is allowed while an uncertain send remains fenced.
                guard attempt.request.action == .dismiss,
                      !(old.request.action == .dismiss && old.request.episodeID == attempt.request.episodeID) else {
                    throw WorkflowSteeringAdmissionError.unresolved
                }
            }
            if old.isAdmitted { try validateLaterObservation(observation, after: old) }
        }
    }

    private func validateLaterObservation(_ observation: WorkflowSteeringObservation, after old: WorkflowSteeringAttempt) throws {
        if case .admitted(let receipt) = old.outcome {
            guard observation.status.sequence >= receipt.sequence,
                  observation.status.controlRevision >= receipt.controlRevision else {
                throw WorkflowSteeringAdmissionError.staleObservation
            }
        } else if let row = old.admissionHistory {
            guard observation.status.sequence >= row.sequence else { throw WorkflowSteeringAdmissionError.staleObservation }
        }
    }

    func pruneResolvedLocked(_ observation: WorkflowSteeringObservation) {
        let removed = retained.filter { attempt in
            guard attempt.outcome != nil, !attempt.isIndeterminate,
                  attempt.request.status.rootID == observation.status.rootID,
                  attempt.runtime.context.expectedStateRoot == observation.runtime.context.expectedStateRoot,
                  let settled = attempt.settledReadOrdinal, observation.readOrdinal > settled else { return false }
            if attempt.refusalEstablished { return true }
            guard attempt.isAdmitted else { return false }
            return (try? validateLaterObservation(observation, after: attempt)) != nil
        }
        let ids = Set(removed.map(\.id))
        retainedBytes -= removed.reduce(0) { $0 + payloadBytes($1) }
        retained.removeAll { ids.contains($0.id) }
    }

    func reconcileUnchangedLocked(_ observation: WorkflowSteeringObservation) {
        for index in retained.indices {
            let attempt = retained[index]
            guard attempt.isIndeterminate, attempt.admissionHistory == nil,
                  attempt.generation == observation.generation, attempt.runtime == observation.runtime,
                  let settled = attempt.settledReadOrdinal, observation.readOrdinal > settled,
                  case .indeterminate(let failure) = attempt.outcome,
                  failure.definiteExit, failure.auditedProducer, !failure.hasReceiptReference, failure.structuredCode != nil else { continue }
            let before = attempt.request.status
            let after = observation.status
            guard before.rootID == after.rootID, before.productVersion == "0.0.14", after.productVersion == before.productVersion,
                  before.schemaVersion == after.schemaVersion, before.ledgerEpoch == after.ledgerEpoch,
                  before.interactionEpoch == after.interactionEpoch, before.controlRevision == after.controlRevision,
                  before.sequence == after.sequence, before.owner == after.owner, before.episodes == after.episodes else { continue }
            let oldBytes = payloadBytes(retained[index])
            retained[index].refusalEstablished = true
            retainedBytes += payloadBytes(retained[index]) - oldBytes
            // The command outcome remains intact. Positive matching evidence can still take precedence.
        }
    }

    func reconcileHistoryLocked(_ page: WorkflowSteeringHistoryPage, observation: WorkflowSteeringObservation) {
        for index in retained.indices {
            let attempt = retained[index]
            guard attempt.outcome != nil, attempt.admissionHistory == nil,
                  attempt.runtime.context.expectedStateRoot == observation.runtime.context.expectedStateRoot,
                  let settled = attempt.settledReadOrdinal, observation.readOrdinal > settled,
                  let evidence = page.admissionEvidence(for: attempt.request, status: observation.status) else { continue }
            // Fresh UUID, exact text/action/episode and a later absolute sequence are positive proof.
            // Different selection generations cannot establish absence, but do not erase this proof.
            let oldBytes = payloadBytes(retained[index])
            retained[index].admissionHistory = evidence
            retained[index].refusalEstablished = false
            retainedBytes += payloadBytes(retained[index]) - oldBytes
        }
    }
}
