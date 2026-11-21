import Combine
import Foundation
import HfRepository
import MonitorCore

// MARK: - WorkflowSteeringDraftScope

struct WorkflowSteeringDraftScope: Equatable {
    let rootID: String
    let runtime: QualificationRuntimeToken
}

struct WorkflowSteeringDraftCapture {
    let scope: WorkflowSteeringDraftScope
    let revision: UInt64
    let generation: UInt64
    var admitted = false
}

// MARK: - WorkflowSteeringAuthority

/// Opaque identity minted only for one checked production display; previews supply no authority.
struct WorkflowSteeringAuthority: Equatable {
    fileprivate let id: UUID
}

struct WorkflowSteeringDisplay {
    var isRevalidating = false
    var presentation = WorkflowSteeringPresentation()
    var observation: WorkflowSteeringObservation?
    var authority: WorkflowSteeringAuthority?
    var lease: UUID?
    var visibilityEpoch: UInt64?
    var run: WorkflowRunModel?
}

// MARK: - WorkflowVM steering lifecycle

extension WorkflowVM {
    var steering: WorkflowSteeringPresentation {
        get { steeringDisplay.presentation }
        set { steeringDisplay = WorkflowSteeringDisplay(presentation: newValue) }
    }

    var steeringAuthority: WorkflowSteeringAuthority? { steeringDisplay.authority }
    var steeringRevalidating: Bool { steeringDisplay.isRevalidating }
    var steeringObservation: WorkflowSteeringObservation? { steeringDisplay.observation }

    /// Positive displayed hold survives its own revalidation; it never grants command admission.
    var steeringHeaderHold: Bool? {
        guard let run = selectedRun, WorkflowSteeringPresentation.isRegularRoot(run.raw),
              WorkflowSteeringRunContext.matches(steeringDisplay.run, run),
              let observation = steeringDisplay.observation, observation.status.rootID == run.id,
              (try? useCase.activityRuntime()) == observation.runtime else { return nil }
        let hold = observation.status.episodes.contains(where: \.hold)
        if useCase.isSteeringCurrent(observation) { return hold }
        return steeringRevalidating && hold ? true : nil
    }

    func startSteeringObservation() {
        steeringVisibilitySubscription = Self.steeringVisibilityPublisher(visibility, fence: steeringVisibilityFence)
            .receive(on: DispatchQueue.main)
.sink { [weak self] visible in
                guard let self else { return }
                invalidateSteeringRead()
                if visible { requestSteeringRead() }
            }
        updateSteeringSelection()
    }

    var steeringOwnsComposer: Bool {
        guard let run = selectedRun, WorkflowSteeringPresentation.isRegularRoot(run.raw),
              isOrchestratorSelected, runGraphVisible else { return false }
        return true
    }

    var steeringCanRead: Bool {
        didSubscribe && visibility.mainWindowVisible && steeringOwnsComposer && initialLoadingKind == nil && !initialLoadFailed
    }

    var steeringFailedQueue: Bool {
        steeringOwnsComposer && !messagingUnsupported && selectedRun?.status == "failed" && !steering.isHeld
            && selectedRun.map { !WorkflowSteeringPresentation.hasPositiveHold($0.raw) } == true
            && currentSteeringAttempts.allSatisfy { $0.refusalEstablished || $0.isAdmitted }
            && !steeringActionPending && (steeringUnsupported || steeringObservation.map {
                useCase.isSteeringCurrent($0) && !$0.status.episodes.contains(where: \.hold)
            } == true)
    }

    var currentSteeringAttempts: [WorkflowSteeringAttempt] {
        guard let root = selectedRun?.id, let runtime = try? useCase.activityRuntime() else { return [] }
        return useCase.steeringAttempts(rootID: root).filter { $0.runtime == runtime }
    }

    func invalidateSteeringRead(preservingEditing: Bool = false) {
        steeringLease = UUID()
        steeringReadTask?.cancel()
        var presentation = steering
        if !preservingEditing {
            presentation.action = nil
            presentation.canDismiss = false
        }
        steeringDisplay = WorkflowSteeringDisplay(isRevalidating: preservingEditing, presentation: presentation)
    }

    func steeringRunDidChange(from previous: WorkflowRunModel?) {
        guard !WorkflowSteeringRunContext.matches(previous, selectedRun) else { return }
        invalidateSteeringRead(preservingEditing: canPreserveSteeringEditing(from: previous))
    }

    private func canPreserveSteeringEditing(from previous: WorkflowRunModel?) -> Bool {
        guard let run = selectedRun, previous?.id == run.id, steering.action != nil, !steeringUnsupported,
              WorkflowSteeringPresentation.isRegularRoot(run.raw), !WorkflowSteeringPresentation.hasPendingQuestion(run.raw),
              !["completed", "failed", "cancelled", "cancelling"].contains(run.status),
              (try? useCase.activityRuntime()) == steeringScope?.runtime else { return false }
        let episode = steeringObservation?.status.heldRootEpisode
        let summary = run.raw["steering_summary"]
        if let id = summary?["episode_id"]?.stringValue, id != episode?.id { return false }
        if let state = summary?["state"]?.stringValue, state != episode?.state { return false }
        if let hold = summary?["hold"]?.boolValue, hold != (episode?.hold ?? false) { return false }
        return true
    }

    func updateSteeringSelection() {
        let scope = selectedRun.flatMap { run in (try? useCase.activityRuntime()).map { WorkflowSteeringDraftScope(rootID: run.id, runtime: $0) } }
        if scope != steeringScope {
            if let old = steeringScope {
                steeringDrafts.removeAll { $0.0 == old }
                steeringDrafts.append((old, steeringDraft, steeringEditRevision))
            }
            steeringScope = scope
            let parked = scope.flatMap { scope in steeringDrafts.first { $0.0 == scope } }
            steeringRestoringDraft = true
            steeringDraft = parked?.1 ?? ""
            steeringEditRevision = parked?.2 ?? 0
            steeringRestoringDraft = false
            steeringProgress = WorkflowSteeringHistoryProgress()
            steeringProvenance = nil
            steering = WorkflowSteeringPresentation()
            steeringUnsupported = false
            invalidateSteeringRead()
        } else if !steeringOwnsComposer || !visibility.mainWindowVisible {
            invalidateSteeringRead()
        }
        if let run = selectedRun {
            var next = steering
            _ = next.applyPhase(run.status)
            if next.isDismissed, contradictsDismissedEvidence(run.raw, episodeID: next.dismissedEpisodeID) {
                next.isDismissed = false
                next.dismissedEpisodeID = nil
            }
            if next != steering { steering = next }
        }
        applySteeringComposerOwnership()
        requestSteeringRead()
    }

    private func contradictsDismissedEvidence(_ raw: [String: JSONValue], episodeID: String?) -> Bool {
        if WorkflowSteeringPresentation.hasPositiveHold(raw) { return true }
        if let state = raw["steering_summary"]?["state"]?.stringValue, state != "dismissed" { return true }
        if let currentEpisode = raw["steering_summary"]?["episode_id"]?.stringValue { return currentEpisode != episodeID }
        return false
    }

    func applySteeringComposerOwnership() {
        let regularRoot = selectedRun.map { WorkflowSteeringPresentation.isRegularRoot($0.raw) } == true
        for (key, activity) in activityCache {
            activity.setSteeringComposerOwned(regularRoot && key.hasPrefix(WorkflowStandalone.orchestratorID + ":"))
        }
    }

    func requestSteeringRead() {
        guard steeringCanRead, steeringReadTask == nil, !steeringActionPending, let root = selectedRun?.id else { return }
        let lease = steeringLease
        steeringLeaseVisibilityEpoch = steeringVisibilityFence.epoch
        if !steeringDisplay.isRevalidating {
            var pending = steeringDisplay
            pending.isRevalidating = true
            pending.authority = nil
            steeringDisplay = pending
        }
        steeringReadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                steeringReadTask = nil
                if steeringLease != lease { requestSteeringRead() }
            }
            await readSteering(root: root, lease: lease)
        }
    }

    private func readSteering(root: String, lease: UUID) async {
        do {
            let observation = try await useCase.steeringObservation(rootID: root)
            guard steeringReadIsCurrent(root: root, lease: lease), useCase.isSteeringCurrent(observation) else { return }
            let observedAt = Date()
            let historyNeeded = prepareSteeringHistory(observation)
            if historyNeeded { try await readSteeringHistory(observation, root: root, lease: lease) }
            guard steeringReadIsCurrent(root: root, lease: lease), useCase.isSteeringCurrent(observation), let run = selectedRun else { return }
            reconcileSteeringDrafts(observation: observation)
            let unresolved = currentSteeringAttempts.contains { !$0.isAdmitted && !$0.refusalEstablished }
            let history = steeringProgress.rows
            let partialHistory = steeringProgress.incomplete || steeringProgress.catchingUp
            let status = observation.status
            let runtime = observation.runtime
            let next = await Task.detached(priority: .userInitiated) {
                let audited = CtlClient(executable: runtime.executable, environment: runtime.environment,
                                        compatibilityContext: runtime.context).isAuditedSteeringProducer
                return WorkflowSteeringPresentation.make(status: status, run: run, history: history, observedAt: observedAt,
                                                         unresolved: unresolved, partialHistory: partialHistory, auditedProducer: audited)
            }.value
            guard steeringReadIsCurrent(root: root, lease: lease), useCase.isSteeringCurrent(observation),
                  WorkflowSteeringRunContext.matches(selectedRun, run) else { return }
            steeringDisplay = WorkflowSteeringDisplay(presentation: next, observation: observation,
                                                      authority: WorkflowSteeringAuthority(id: UUID()), lease: lease,
                                                      visibilityEpoch: steeringVisibilityFence.epoch, run: run)
        } catch {
            guard steeringReadIsCurrent(root: root, lease: lease) else { return }
            applySteeringReadFailure(error)
        }
        applySteeringComposerOwnership()
    }

    private func prepareSteeringHistory(_ observation: WorkflowSteeringObservation) -> Bool {
        if let old = steeringProvenance, old.0 != observation.runtime || old.1 != observation.generation {
            steeringProgress = WorkflowSteeringHistoryProgress()
        }
        steeringProvenance = (observation.runtime, observation.generation)
        steeringUnsupported = false
        let status = observation.status
        let previous = steeringObservation?.status
        if let floor = status.historyFloor, floor != steeringProgress.floor {
            if steeringProgress.floor != nil { steeringProgress.incomplete = true }
            steeringProgress.floor = floor
            // A floor is not evidence of receiving its boundary row. The public initial page owns the start.
            steeringProgress.cursor = nil
            steeringProgress.catchingUp = true
        }
        return previous?.sequence != status.sequence || previous?.ledgerEpoch != status.ledgerEpoch
            || previous?.episodes != status.episodes || steeringProgress.catchingUp
    }

    private func readSteeringHistory(_ observation: WorkflowSteeringObservation, root: String, lease: UUID) async throws {
        for _ in 0 ..< 4 {
            let page = try await useCase.steeringHistory(observation: observation, cursor: steeringProgress.cursor)
            guard steeringReadIsCurrent(root: root, lease: lease), useCase.isSteeringCurrent(observation) else { throw CancellationError() }
            if !steeringProgress.consume(page, horizon: observation.status.sequence) { break }
        }
        steeringProgress.sequence = observation.status.sequence
    }

    private func applySteeringReadFailure(_ error: any Error) {
        if case .unsupportedCommand(let tool, let command, let detail) = error as? ToolError,
           tool == "harflow-ctl", command == "workflow-steering-status",
           ["Missing capability workflow-steering-read.v1", "Missing capability workflow-steering-orchestrator.v1"].contains(detail) {
            steeringUnsupported = true
        }
        steering.action = nil
        steering.canDismiss = false
        steering.partialHistory = true
        // Preserve previously proven hold and unresolved invocation evidence on a failed read.
        if let run = selectedRun { steering.isHeld = steering.isHeld || WorkflowSteeringPresentation.hasPositiveHold(run.raw) }
    }

    private func steeringReadIsCurrent(root: String, lease: UUID) -> Bool {
        !Task.isCancelled && steeringCanRead && steeringLease == lease && selectedRun?.id == root
            && steeringVisibilityFence.epoch == steeringLeaseVisibilityEpoch
            && (try? useCase.activityRuntime()) == steeringScope?.runtime
    }

    func submitSteering(_ text: String) { submitSteering(text, authority: steeringAuthority) }
    func dismissSteering() { dismissSteering(authority: steeringAuthority) }
    func openSteeringNeedsYou() { openSteeringNeedsYou(authority: steeringAuthority) }

    func submitSteering(_ text: String, authority: WorkflowSteeringAuthority?) {
        guard let observation = displayedSteeringObservation(authority), let action = steering.action,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        performSteering(action: action, text: text, observation: observation)
    }

    func dismissSteering(authority: WorkflowSteeringAuthority?) {
        guard let observation = displayedSteeringObservation(authority) else { return }
        performSteering(action: .dismiss, text: nil, observation: observation)
    }

    func openSteeringNeedsYou(authority: WorkflowSteeringAuthority?) {
        guard displayedSteeringObservation(authority) != nil, steering.opensNeedsYou else { return }
        routing.showNeedsYou(itemID: nil)
    }

    private func displayedSteeringObservation(_ authority: WorkflowSteeringAuthority?) -> WorkflowSteeringObservation? {
        guard !steeringDisplay.isRevalidating, let authority, steeringDisplay.authority == authority, steeringDisplay.lease == steeringLease,
              steeringDisplay.visibilityEpoch == steeringVisibilityFence.epoch, WorkflowSteeringRunContext.matches(steeringDisplay.run, selectedRun),
              steeringCanRead, let observation = steeringDisplay.observation,
              useCase.isSteeringCurrent(observation) else { return nil }
        return observation
    }

    private func performSteering(action: WorkflowSteeringAction, text: String?, observation: WorkflowSteeringObservation) {
        let terminal = ["completed", "failed", "cancelled", "cancelling"].contains(selectedRun?.status ?? "")
        let eligible = action == .dismiss ? steering.canDismiss : steering.action == action && !terminal
        guard steeringCanRead, !steeringActionPending,
              useCase.isSteeringCurrent(observation), observation.status.permits(action),
              eligible,
              let scope = steeringScope else { return }
        let capture = WorkflowSteeringDraftCapture(scope: scope, revision: steeringEditRevision, generation: observation.generation)
        let lease = steeringLease
        steeringActionPending = true
        steering.action = nil
        steering.canDismiss = false
        // Explicit invocations belong to the app-session repository. Display teardown never cancels this task.
        Task { [self] in
            do {
                let attempt = try await useCase.performSteering(action: action, text: text, observation: observation)
                if text != nil {
                    if attempt.isAdmitted || !attempt.refusalEstablished {
                        var retained = capture
                        retained.admitted = attempt.isAdmitted
                        steeringCaptures[attempt.id] = retained
                    }
                }
            } catch {
                // Local admission refusal preserves the draft and never retries the mutation.
            }
            steeringActionPending = false
            if steeringLease == lease, steeringCanRead, steeringScope == scope { requestSteeringRead() }
        }
    }

    private func reconcileSteeringDrafts(observation: WorkflowSteeringObservation) {
        guard useCase.isSteeringCurrent(observation) else { return }
        for attempt in currentSteeringAttempts where attempt.isAdmitted {
            if var capture = steeringCaptures[attempt.id] {
                capture.admitted = true
                steeringCaptures[attempt.id] = capture
            }
        }
        for (id, capture) in steeringCaptures {
            guard capture.scope.runtime == observation.runtime else { continue }
            if capture.generation != observation.generation {
                steeringCaptures.removeValue(forKey: id)
            } else if capture.admitted {
                clearSteeringDraft(capture, observation: observation)
                steeringCaptures.removeValue(forKey: id)
            }
        }
    }

    private func clearSteeringDraft(_ capture: WorkflowSteeringDraftCapture, observation: WorkflowSteeringObservation) {
        guard useCase.isSteeringCurrent(observation), observation.generation == capture.generation,
              observation.runtime == capture.scope.runtime else { return }
        if steeringScope == capture.scope {
            guard steeringEditRevision == capture.revision else { return }
            steeringDraft = ""
        } else if let index = steeringDrafts.firstIndex(where: { $0.0 == capture.scope && $0.2 == capture.revision }) {
            steeringDrafts[index] = (capture.scope, "", capture.revision &+ 1)
        }
    }

}

// MARK: - WorkflowSteeringVisibilityFence

/// Inline visibility revocation survives an entire hide/show interval before main-queue delivery.
final class WorkflowSteeringVisibilityFence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    var epoch: UInt64 { lock.withLock { value } }
    func invalidate() { lock.withLock { value &+= 1 } }
}

extension WorkflowVM {
    nonisolated static func steeringVisibilityPublisher(
        _ visibility: any MonitorVisibility,
        fence: WorkflowSteeringVisibilityFence
    ) -> AnyPublisher<Bool, Never> {
        visibility.mainWindowVisiblePublisher()
.map { visible in
            fence.invalidate()
            return visible
        }
.eraseToAnyPublisher()
    }
}
