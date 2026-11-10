import Combine
import Foundation
import HfRepository
import MonitorCore

// MARK: - Standalone Continue

extension TaskDetailVM {
    private var continuationRequest: TaskContinuationRequest? {
        guard chrome == .standalone, let runtime = useCase.continuationRuntime() ?? continuationSession.runtime else { return nil }
        return .init(runtime: runtime, conversationID: topBarConversationID, sourceTaskID: currentTaskID)
    }

    var continuationLocksActions: Bool { continuationPresentation?.locksActions == true }

    /// Read raw runtime and owner state, not a potentially queued presentation publication.
    var continuationLocksActionsFresh: Bool {
        guard let request = continuationRequest else { return false }
        if continuationSession.submittedRequest?.runtime == request.runtime { return true }
        guard let attempt = useCase.continuationOwner().state(for: request) else { return false }
        return continuationLocked(attempt, current: currentTaskID)
    }

    var continuationPlaceholder: String {
        continuationPresentation?.phase == .starting ? "Starting a new session…" : "Locked until the new session is checked"
    }

    private func continuationLocked(_ attempt: TaskContinuationAttempt, current: String) -> Bool {
        guard attempt.request.runtime == (useCase.continuationRuntime() ?? continuationSession.runtime) else { return false }
        switch attempt.outcome {
        case nil: return true
        case .uncertain?: return !attempt.permitsRecordedSource(current)
        case .launched(let acknowledged)?:
            guard attempt.permitsRecordedSource(current) else { return true }
            let rows = Dictionary(conversationMembers.map { ($0.taskID, $0) }, uniquingKeysWith: { first, _ in first })
            var cursor = current
            var visited = Set<String>()
            while visited.insert(cursor).inserted, visited.count <= 400 {
                if cursor == acknowledged { return false }
                guard let row = rows[cursor], let predecessor = row.continuationOfTaskID ?? row.parentTaskID else { return true }
                cursor = predecessor
            }
            return true
        default: return false
        }
    }

    func prepareContinuation(task: TaskInfo) {
        guard chrome == .standalone, isMounted else { return }
        let session = continuationSession
        let runtime = useCase.continuationRuntime() ?? session.runtime
        if session.observation == nil {
            session.observation = useCase.continuationOwner()
.changesPublisher()
                .receive(on: DispatchQueue.main)
.sink { [weak self] _ in
                    guard let self, isMounted else { return }
                    recompute()
                }
        }
        if runtime != session.runtime || task.taskID != session.taskID {
            session.generation = UUID()
            session.supportRead?.cancel()
            session.adoptionRead?.cancel()
            session.adoptionRead = nil
            session.runtime = runtime
            session.taskID = task.taskID
            session.statusRevision = useCase.statusReadOutcome(task.taskID)?.revision
            session.supported = false
            session.checkedGoals = []
            session.observedAttempts = []
            if let runtime {
                let generation = session.generation
                session.supportRead = Task { [weak self, useCase] in
                    let supported = await useCase.continuationSupport(runtime: runtime)
                    guard let self, isMounted, session.generation == generation,
                          useCase.continuationRuntime() == runtime, !Task.isCancelled else { return }
                    session.supported = supported
                    recompute()
                }
            }
        }
        // Retained attempts are queried even when the capability read failed.
        if let submitted = session.submittedRequest, submitted.runtime == runtime {
            continuationPresentation = .init(taskID: task.taskID, phase: .starting, exitCode: matchingExit(task), status: task.status, locksActions: true)
            return
        }
        let attempt = continuationRequest.flatMap { useCase.continuationOwner().state(for: $0) }
        continuationPresentation = continuationModel(task: task, attempt: attempt)
        if let attempt { observeContinuationAdoption(attempt) }
    }

    private func continuationModel(task: TaskInfo, attempt: TaskContinuationAttempt?) -> TaskContinuationPresentation? {
        if let attempt {
            let locked = continuationLocked(attempt, current: task.taskID)
            let phase: TaskContinuationPresentation.Phase?
            var message: String?
            switch attempt.outcome {
            case nil: phase = .starting
            case .uncertain?: phase = locked ? .unknown : nil
            case .engineError(let error)?:
                phase = attempt.request.sourceTaskID == task.taskID ? .refused : nil
                message = error.message
            case .launched(let id)?: phase = locked || (id == task.taskID && task.status.isRunning) ? .accepted : nil
            case .notDispatched?: phase = nil
            }
            if let phase {
                return .init(taskID: task.taskID, phase: phase, attemptID: attempt.id, exitCode: matchingExit(task), status: task.status,
                             message: message, canCheck: phase == .unknown && useCase.continuationRuntime() == attempt.request.runtime,
                             isChecking: attempt.check == .checking, locksActions: locked)
            }
        }
        guard useCase.continuationRuntime() != nil, continuationSession.supported, !task.takenOver, [.failed, .cancelled, .timedOut].contains(task.status),
              matchingExit(task) != nil, !isWorkflowBuilder, !WorkflowNodePresentation.isNativeControl(task) else { return nil }
        return .init(taskID: task.taskID, phase: .eligible, exitCode: matchingExit(task), status: task.status,
                     canContinue: continuationSession.supported && hasStatusAuthority && !isBusy)
    }

    private func matchingExit(_ task: TaskInfo) -> Int? {
        guard let snapshot = useCase.statusReadOutcome(task.taskID)?.task,
              snapshot.taskID == task.taskID, snapshot.status == task.status else { return nil }
        return snapshot.exitCode
    }

    func didTapContinue(taskID renderedID: String) {
        guard isMounted, chrome == .standalone, renderedID == currentTaskID,
              let task = latestActionTask(), matchingExit(task) != nil,
              [.failed, .cancelled, .timedOut].contains(task.status), !task.takenOver,
              !isWorkflowBuilder, !WorkflowNodePresentation.isNativeControl(task), !isBusy,
              continuationSession.supported, let request = continuationRequest,
              continuationSession.runtime == request.runtime, useCase.continuationRuntime() == request.runtime else { return }
        let owner = useCase.continuationOwner()
        continuationSession.submittedRequest = request
        continuationPresentation = .init(taskID: renderedID, phase: .starting, exitCode: matchingExit(task), status: task.status, locksActions: true)
        recompute()
        // This task deliberately has no VM teardown cancellation owner.
        Task { [weak self, useCase] in
            let result = await owner.start(request)
            if self?.continuationSession.submittedRequest == request { self?.continuationSession.submittedRequest = nil }
            if case .refused = result { useCase.setOutcome(renderedID, "Continue is unavailable. Review the current task and try again.") }
            if let attempt = owner.state(for: request), case .notDispatched? = attempt.outcome {
                useCase.setOutcome(renderedID, "Continue was not dispatched. Review the selected engine and try again.")
            }
            guard let self, isMounted, useCase.continuationRuntime() == request.runtime else { return }
            recompute()
        }
    }

    func didTapCheckContinuation(taskID renderedID: String, attemptID: UUID) {
        guard isMounted, renderedID == currentTaskID, let request = continuationRequest,
              let attempt = useCase.continuationOwner().state(for: request), attempt.id == attemptID,
              attempt.request.runtime == request.runtime, attempt.check != .checking else { return }
        let owner = useCase.continuationOwner()
        let generation = continuationSession.generation
        Task { [weak self] in
            if renderedID == attempt.request.sourceTaskID {
                await owner.check(attemptID: attemptID)
            } else { await owner.check(attemptID: attemptID, targetSourceTaskID: renderedID) }
            guard let self, isMounted, continuationSession.generation == generation, currentTaskID == renderedID,
                  useCase.continuationRuntime() == request.runtime, !Task.isCancelled else { return }
            continuationSession.observedAttempts.remove(attemptID)
            recompute()
        }
    }

    func didTapNewTask() { routing.showNewTask() }

    private func observeContinuationAdoption(_ attempt: TaskContinuationAttempt) {
        let session = continuationSession
        guard attempt.outcome != nil, attempt.request.runtime == session.runtime else { return }
        let goal = currentTaskID
        let key = attempt.id.uuidString + "/" + goal
        let needsProof = goal != attempt.request.sourceTaskID && !attempt.permitsRecordedSource(goal)
        let needsObservation: Bool = switch attempt.outcome {
        case .launched?, .uncertain?: !session.observedAttempts.contains(attempt.id)
        default: false
        }
        guard session.adoptionRead == nil,
              (needsProof && !session.checkedGoals.contains(key) && attempt.check != .checking) || needsObservation else { return }
        let generation = session.generation
        let owner = useCase.continuationOwner()
        session.adoptionRead = Task { [weak self, useCase] in
            defer { if session.generation == generation { session.adoptionRead = nil } }
            guard self?.isMounted == true, session.generation == generation,
                  useCase.continuationRuntime() == attempt.request.runtime, !Task.isCancelled else { return }
            if needsProof {
                await owner.check(attemptID: attempt.id, targetSourceTaskID: goal)
                guard let self, isMounted, session.generation == generation,
                      useCase.continuationRuntime() == attempt.request.runtime, !Task.isCancelled else { return }
                if owner.state(for: attempt.request)?.check != .checking { session.checkedGoals.insert(key) }
            }
            if needsObservation {
                session.observedAttempts.insert(attempt.id)
                await self?.readContinuationSuccessors(attempt, generation: generation)
            }
            guard let self, isMounted, session.generation == generation,
                  useCase.continuationRuntime() == attempt.request.runtime, !Task.isCancelled else { return }
            recomputeMembersAndLeases()
        }
    }

    private func readContinuationSuccessors(_ attempt: TaskContinuationAttempt, generation: UUID) async {
        let session = continuationSession
        do {
            _ = try await useCase.observeSuccessors(attempt.request.sourceTaskID)
            guard isMounted, session.generation == generation,
                  useCase.continuationRuntime() == attempt.request.runtime, !Task.isCancelled else { return }
            publishViewEvent(.incidentResolved(source: "task-continuation-" + topBarConversationID))
        } catch {
            guard isMounted, session.generation == generation,
                  useCase.continuationRuntime() == attempt.request.runtime, !Task.isCancelled else { return }
            publishViewEvent(.incident(source: "task-continuation-" + topBarConversationID,
                                      message: "Conversation history could not be loaded. Refresh the current status to check again."))
        }
    }

    /// Existing public read pulses admit one more bounded observation; never a launch retry.
    func continuationReadPulse() {
        guard chrome == .standalone else { return }
        continuationSession.checkedGoals = []
        continuationSession.observedAttempts = []
    }

    func stopContinuationPresentation() {
        let session = continuationSession
        session.generation = UUID()
        session.supportRead?.cancel()
        session.adoptionRead?.cancel()
        session.supportRead = nil
        session.adoptionRead = nil
        session.observation = nil
        // Retain the last selected binding for unsafe-owner lookup during temporary tooling loss.
        session.taskID = nil
        session.supported = false
        continuationPresentation = nil
    }
}
