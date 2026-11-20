import Combine
import Foundation
import MonitorCore

// MARK: - WorkflowSteeringRepositoryImpl

/// Synchronous generation fences and atomic reservations; no lock spans dependency calls or awaits.
public final class WorkflowSteeringRepositoryImpl: WorkflowSteeringRepository, @unchecked Sendable {
    let tooling: any ToolEnvironmentRepository
    let lock = NSLock()
    var generation: UInt64 = 0
    var readOrdinal: UInt64 = 0
    var latestReads: [String: UInt64] = [:]
    var activeReads = 0
    var observations: [String: WorkflowSteeringObservation] = [:]
    var retained: [WorkflowSteeringAttempt] = []
    var subscription: AnyCancellable?
    var retainedBytes = 0
    var reservations: [UUID: Int] = [:]
    static let maximumAttempts = 256
    static let maximumBytes = 32 << 20
    static let invocationReservation = 4 << 20

    /// Uses selected-runtime public ctl operations only.
    public init(tooling: any ToolEnvironmentRepository) { self.tooling = tooling }

    /// Inline invalidation preserves unsafe attempts and revokes observations even across A→B→A.
    public func bindRuntimeChanges(_ publisher: AnyPublisher<ManagedRuntimeState, Never>) {
        subscription = publisher.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            lock.withLock {
                if generation < UInt64.max { generation += 1 }
                observations.removeAll()
                latestReads.removeAll()
            }
        }
    }

    public func attempts(rootID: String) -> [WorkflowSteeringAttempt] {
        lock.withLock { retained.filter { $0.request.status.rootID == rootID } }
    }

    public func isCurrent(_ observation: WorkflowSteeringObservation) -> Bool {
        guard let client = try? tooling.ctl().get(), QualificationRuntimeToken(client: client) == observation.runtime else { return false }
        return lock.withLock { currentLocked(observation) }
    }

    func currentLocked(_ observation: WorkflowSteeringObservation) -> Bool {
        generation < UInt64.max && readOrdinal < UInt64.max && generation == observation.generation && observations[observation.status.rootID]?.id == observation.id
            && latestReads[observation.status.rootID] == observation.readOrdinal
    }

    func capture() throws -> (CtlClient, QualificationRuntimeToken, UInt64) {
        let epoch = lock.withLock { generation }
        guard epoch < UInt64.max else { throw WorkflowSteeringAdmissionError.capacity }
        var client = try tooling.ctl().get()
        let runtime = QualificationRuntimeToken(client: client)
        let bytes = runtime.environment.reduce(runtime.executable.utf8.count) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        guard bytes <= 65536 else { throw WorkflowSteeringAdmissionError.capacity }
        guard lock.withLock({ generation == epoch }) else { throw WorkflowSteeringAdmissionError.runtimeChanged }
        let original = client.operationIsCurrent
        client.operationIsCurrent = { [weak self] in
            guard original(), let self, let selected = try? tooling.ctl().get(), QualificationRuntimeToken(client: selected) == runtime else { return false }
            return lock.withLock { generation == epoch }
        }
        return (client, runtime, epoch)
    }

    public func observation(rootID: String) async throws -> WorkflowSteeringObservation {
        guard rootID.count == 32, rootID.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }) else {
            throw WorkflowSteeringAdmissionError.staleObservation
        }
        try beginRead()
        defer { lock.withLock { activeReads -= 1 } }
        let (client, runtime, epoch) = try capture()
        let ordinal = try lock.withLock {
            makeObservationRoomLocked(rootID: rootID)
            guard generation == epoch else { throw WorkflowSteeringAdmissionError.runtimeChanged }
            guard readOrdinal < UInt64.max else { throw WorkflowSteeringAdmissionError.capacity }
            readOrdinal += 1
            latestReads[rootID] = readOrdinal
            observations.removeValue(forKey: rootID)
            return readOrdinal
        }
        let status = try await client.workflowSteeringStatus(rootID: rootID).get()
        guard !Task.isCancelled, client.operationIsCurrent() else { throw WorkflowSteeringAdmissionError.runtimeChanged }
        let observation = WorkflowSteeringObservation(status: status, runtime: runtime, generation: epoch, readOrdinal: ordinal, id: UUID())
        return try lock.withLock {
            guard generation == epoch else { throw WorkflowSteeringAdmissionError.runtimeChanged }
            guard latestReads[rootID] == ordinal else { throw WorkflowSteeringAdmissionError.staleObservation }
            observations[rootID] = observation
            pruneResolvedLocked(observation)
            reconcileUnchangedLocked(observation)
            return observation
        }
    }

    public func history(observation: WorkflowSteeringObservation, cursor: String? = nil) async throws -> WorkflowSteeringHistoryPage {
        try beginRead()
        defer { lock.withLock { activeReads -= 1 } }
        guard isCurrent(observation) else { throw WorkflowSteeringAdmissionError.staleObservation }
        let (client, runtime, epoch) = try capture()
        guard runtime == observation.runtime, epoch == observation.generation else { throw WorkflowSteeringAdmissionError.runtimeChanged }
        let page = try await client.workflowSteeringHistory(rootID: observation.status.rootID, cursor: cursor).get()
        guard !Task.isCancelled, client.operationIsCurrent() else { throw WorkflowSteeringAdmissionError.runtimeChanged }
        try lock.withLock {
            guard currentLocked(observation) else { throw WorkflowSteeringAdmissionError.staleObservation }
            reconcileHistoryLocked(page, observation: observation)
        }
        return page
    }

    public func perform(action: WorkflowSteeringAction, text: String? = nil,
                        observation: WorkflowSteeringObservation) async throws -> WorkflowSteeringAttempt {
        guard isCurrent(observation), !Task.isCancelled else { throw WorkflowSteeringAdmissionError.staleObservation }
        let (client, runtime, epoch) = try capture()
        guard runtime == observation.runtime, epoch == observation.generation else { throw WorkflowSteeringAdmissionError.runtimeChanged }
        let id = UUID()
        let request = try WorkflowSteeringRequest(status: observation.status, action: action, text: text, requestID: id)
        let attempt = WorkflowSteeringAttempt(id: id, request: request, runtime: runtime, generation: epoch,
                                              outcome: nil, admissionHistory: nil, refusalEstablished: false, settledReadOrdinal: nil)
        try lock.withLock {
            guard currentLocked(observation) else { throw WorkflowSteeringAdmissionError.staleObservation }
            try admitLocked(attempt, observation: observation)
            retained.append(attempt)
            reservations[id] = Self.invocationReservation
            retainedBytes += Self.invocationReservation
            observations.removeValue(forKey: observation.status.rootID)
            if readOrdinal < UInt64.max { readOrdinal += 1 }
            latestReads[observation.status.rootID] = readOrdinal
        }
        // Once reserved, the owner retains phase-aware completion even if the view or runtime disappears.
        let outcome = await client.workflowSteer(request)
        return lock.withLock {
            guard let index = retained.firstIndex(where: { $0.id == id }) else { return attempt }
            retained[index].outcome = outcome
            if readOrdinal < UInt64.max { readOrdinal += 1 }
            if generation == epoch {
                makeObservationRoomLocked(rootID: observation.status.rootID)
                observations.removeValue(forKey: observation.status.rootID)
                latestReads[observation.status.rootID] = readOrdinal
            }
            retained[index].settledReadOrdinal = readOrdinal
            switch outcome {
            case .notDispatched, .refused: retained[index].refusalEstablished = true
            case .admitted, .indeterminate: break
            }
            let old = reservations.removeValue(forKey: id) ?? 0
            retainedBytes += payloadBytes(retained[index]) - old
            return retained[index]
        }
    }

    private func makeObservationRoomLocked(rootID: String) {
        guard latestReads[rootID] == nil, latestReads.count >= 128,
              let obsolete = latestReads.min(by: { $0.value < $1.value })?.key else { return }
        // Eviction revokes read publication leases only, never retained invocation evidence.
        latestReads.removeValue(forKey: obsolete)
        observations.removeValue(forKey: obsolete)
    }

    private func beginRead() throws {
        try lock.withLock {
            guard activeReads < 16 else { throw WorkflowSteeringAdmissionError.capacity }
            activeReads += 1
        }
    }

    func payloadBytes(_ attempt: WorkflowSteeringAttempt) -> Int {
        // Reserve a maximum history row while an attempt may still need positive admission evidence.
        var count = attempt.request.data.count + attempt.request.status.raw.count + 65536
        if attempt.isIndeterminate, attempt.admissionHistory == nil { count += 1 << 20 }
        if let row = attempt.admissionHistory { count += row.raw.count }
        switch attempt.outcome {
        case .admitted(let receipt): count += receipt.raw.count
        case .indeterminate(let failure), .refused(let failure): count += failure.rawError?.count ?? 0
        default: break
        }
        return count
    }
}
