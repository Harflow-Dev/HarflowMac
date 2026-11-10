import Foundation
import MonitorCore

// MARK: - PendingLaunchRepositoryImpl Stop ownership

extension PendingLaunchRepositoryImpl {
    // Reserve one maximum wire document plus a bounded diagnostic/identity capsule before dispatch.
    static let stopReservation = 1024 * 1024 + 32768
    static let attemptByteLimit = 16 * 1024 * 1024

    public func prepareStop(selection: PendingLaunchSelection) async -> PendingLaunchStopPreparation {
        let read = await check(selection: selection)
        guard read.failure == nil, let item = read.value?.item else { return .failed(read.failure ?? .unavailable) }
        guard item.disposition != .recorded else { return .failed(.recorded) }
        guard item.disposition == .pending, !item.hasUnsupportedObservations,
              let launch = item.launch, launch.state != .notStarted,
              item.cancelSupport == .supported else { return .failed(.unsupported) }
        guard let (capturedEpoch, gate) = context(selection: selection) else { return .failed(.superseded) }
        do {
            let client = try client(gate: gate)
            let confirmation = PendingLaunchStopConfirmation(id: UUID(), taskID: selection.taskID,
                                                             generation: launch.generation,
                                                             runtime: QualificationRuntimeToken(client: client), epoch: capturedEpoch)
            let retained = gate.withCurrent { lock.withLock {
                guard epoch == capturedEpoch, confirmations.count < 128 else { return false }
                confirmations[confirmation.id] = confirmation
                confirmationSelections[confirmation.id] = selection
                return true
            } } == true
            return retained ? .confirmation(confirmation) : .failed(.capacity)
        } catch { return .failed(failure(error)) }
    }

    public func submitStop(confirmation: PendingLaunchStopConfirmation) -> PendingLaunchStopAdmission {
        let gate = PendingLaunchAdmissionGate()
        let admission: PendingLaunchStopAdmission = lock.withLock {
            if let previous = value.attempts.first(where: { $0.confirmation.id == confirmation.id }) { return .existing(previous.id) }
            guard epoch == confirmation.epoch,
                  confirmations.removeValue(forKey: confirmation.id) == confirmation else { return .refused(.changed) }
            confirmationSelections.removeValue(forKey: confirmation.id)
            if let unsafe = value.attempts.last(where: {
                $0.confirmation.runtime == confirmation.runtime && $0.confirmation.taskID == confirmation.taskID &&
                    $0.confirmation.generation == confirmation.generation && Self.isUnsafe($0)
            }) { return .existing(unsafe.id) }
            let requiredBytes = attemptCosts.values.reduce(0, +) + Self.stopReservation + Self.identityCost(confirmation)
            guard value.attempts.count < 256, requiredBytes <= Self.attemptByteLimit else { return .refused(.capacity) }
            let id = UUID()
            attemptCosts[id] = Self.stopReservation + Self.identityCost(confirmation)
            commandGates[id] = gate
            value.attempts.append(.init(id: id, confirmation: confirmation, isExecuting: true))
            return .submitted(id)
        }
        guard case .submitted(let id) = admission else { return admission }
        publish()
        // Not a child of the VM's task. View teardown can revoke reads, not this confirmed command.
        Task { [self] in await executeStop(id: id, confirmation: confirmation, gate: gate) }
        return admission
    }

    private static func isUnsafe(_ attempt: PendingLaunchStopAttempt) -> Bool {
        if attempt.isExecuting { return true }
        guard let outcome = attempt.outcome else { return false }
        if case .notDispatched = outcome { return false }
        return true // engine errors can occur after side effects.
    }

    private func executeStop(id: UUID, confirmation: PendingLaunchStopConfirmation, gate: PendingLaunchAdmissionGate) async {
        guard actions.tryBeginBusy(confirmation.taskID) else { finishStop(id: id, failure: .busy); return }
        defer { actions.endBusy(confirmation.taskID) }
        do {
            let client = try client(gate: gate, runtime: confirmation.runtime)
            guard client.operationIsCurrent() else { finishStop(id: id, failure: .superseded); return }
            let lookup = try await client.taskPendingStatus(taskID: confirmation.taskID).get()
            guard client.operationIsCurrent() else { finishStop(id: id, failure: .superseded); return }
            guard lookup.item.disposition != .recorded else { finishStop(id: id, failure: .recorded); return }
            guard lookup.item.disposition == .pending, !lookup.item.hasUnsupportedObservations,
                  lookup.item.launch?.generation == confirmation.generation,
                  lookup.item.launch?.state != .notStarted,
                  lookup.item.cancelSupport == .supported else { finishStop(id: id, failure: .changed); return }
            guard let request = TaskPendingLaunchStopRequest(taskID: confirmation.taskID) else { finishStop(id: id, failure: .malformed); return }
            // Ordinary full-ID cancel may race a spawn AFTER preflight. No atomic generation guard.
            let outcome = await client.stopPendingLaunch(request)
            // A dispatched command owns its evidence even if navigation/runtime changed meanwhile.
            finishStop(id: id, outcome: outcome)
        } catch { finishStop(id: id, failure: failure(error)) }
    }

    private func finishStop(id: UUID, failure: PendingLaunchFailure? = nil, outcome: TaskPendingLaunchStopOutcome? = nil) {
        let retained = outcome.map(Self.boundedOutcome)
        let boundedFailure = Self.boundedFailure(failure)
        lock.withLock {
            guard let index = value.attempts.firstIndex(where: { $0.id == id }) else { return }
            value.attempts[index].isExecuting = false
            value.attempts[index].preflightFailure = boundedFailure.0
            value.attempts[index].outcome = retained?.0
            value.attempts[index].diagnosticsTruncated = (retained?.1 ?? false) || boundedFailure.1
            commandGates.removeValue(forKey: id)
            attemptCosts[id] = Self.outcomeCost(retained?.0) + Self.identityCost(value.attempts[index].confirmation)
                + Self.failureCost(boundedFailure.0)
        }
        publish()
    }

    private static func boundedFailure(_ failure: PendingLaunchFailure?) -> (PendingLaunchFailure?, Bool) {
        guard case .tool(let error) = failure else { return (failure, false) }
        switch error {
        case .structuredRefusal, .refused: return (failure, false)
        default:
            guard String(describing: error).utf8.count > 8192 else { return (failure, false) }
            let diagnostic = String(error.message.prefix(2048)) + " [diagnostic truncated]"
            return (.tool(.unreadable(tool: "harflow-ctl", exitCode: -1, stderr: diagnostic)), true)
        }
    }

    private static func failureCost(_ failure: PendingLaunchFailure?) -> Int {
        guard let failure else { return 0 }
        if case .tool(.structuredRefusal(let code, let message, let data)) = failure {
            return code.utf8.count + message.utf8.count + JSONValue.object(data).rendered().utf8.count
        }
        return String(describing: failure).utf8.count
    }

    /// Structured engine reasons/data and accepted raw receipts remain verbatim. Only unstructured
    /// diagnostics are shortened, with an explicit marker and separate snapshot flag.
    static func boundedOutcome(_ outcome: TaskPendingLaunchStopOutcome) -> (TaskPendingLaunchStopOutcome, Bool) {
        func text(_ value: String) -> (String, Bool) {
            guard value.utf8.count > 8192 else { return (value, false) }
            return (String(value.prefix(2048)) + " [diagnostic truncated]", true)
        }
        func error(_ value: ToolError) -> (ToolError, Bool) {
            switch value {
            case .structuredRefusal, .refused: return (value, false)
            default:
                let bounded = text(value.message)
                return bounded.1 ? (.unreadable(tool: "harflow-ctl", exitCode: -1, stderr: bounded.0), true) : (value, false)
            }
        }
        switch outcome {
        case .uncertain(let request, .unreadableOutput(let code, let stderr)):
            let bounded = text(stderr)
            return (.uncertain(request, cause: .unreadableOutput(exitCode: code, stderr: bounded.0)), bounded.1)
        case .uncertain(let request, .processFailure(let source)):
            let bounded = error(source)
            return (.uncertain(request, cause: .processFailure(bounded.0)), bounded.1)
        case .uncertain(let request, .incompatibleEnvelope(let source)):
            let bounded = error(source)
            return (.uncertain(request, cause: .incompatibleEnvelope(bounded.0)), bounded.1)
        case .notDispatched(let request, .probeFailed(let source)):
            let bounded = error(source)
            return (.notDispatched(request, cause: .probeFailed(bounded.0)), bounded.1)
        case .notDispatched(let request, .inputFile(let detail)):
            let bounded = text(detail)
            return (.notDispatched(request, cause: .inputFile(detail: bounded.0)), bounded.1)
        case .notDispatched(let request, .launchFailed(let tool, let detail)):
            let bounded = text(detail)
            return (.notDispatched(request, cause: .launchFailed(tool: tool, detail: bounded.0)), bounded.1)
        case .notDispatched(let request, .usageRejected(let detail)):
            let bounded = text(detail)
            return (.notDispatched(request, cause: .usageRejected(detail: bounded.0)), bounded.1)
        default: return (outcome, false)
        }
    }

    static func identityCost(_ confirmation: PendingLaunchStopConfirmation) -> Int {
        1024 + confirmation.runtime.environment.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count + 16 }
            + confirmation.runtime.executable.utf8.count
    }

    static func outcomeCost(_ outcome: TaskPendingLaunchStopOutcome?) -> Int {
        guard let outcome else { return 0 }
        switch outcome {
        case .accepted(let receipt): return JSONValue.object(receipt.raw).rendered().utf8.count
        case .engineError(_, let error):
            return error.code.utf8.count + error.message.utf8.count + JSONValue.object(error.data ?? [:]).rendered().utf8.count
        case .notDispatched(_, .probeFailed(let error)), .uncertain(_, .processFailure(let error)),
             .uncertain(_, .incompatibleEnvelope(let error)):
            if case .structuredRefusal(let code, let message, let data) = error {
                return code.utf8.count + message.utf8.count + JSONValue.object(data).rendered().utf8.count
            }
            return error.message.utf8.count + 256
        default: return String(describing: outcome).utf8.count
        }
    }
}
