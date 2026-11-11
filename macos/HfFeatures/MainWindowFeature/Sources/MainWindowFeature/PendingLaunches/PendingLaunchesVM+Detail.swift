import Foundation
import HfRepository

// MARK: - Selected launch

extension PendingLaunchesVM {
    var detailInput: PendingLaunchDetailInput? {
        selection.map {
            PendingLaunchDetailInput(
                selection: $0,
                flags: .init(
                    firstCheckSettled: firstCheckSettled, handoffFailed: handoffFailed, isBusy: activeOperations > 0,
                    stopPrepareNotSent: stopPrepareNotSent,
                    acknowledgedAttempt: projection.stop.map { acknowledgedAttempts.contains($0.latest.attemptID) } ?? false,
                    notSentCleared: notSentCleared
                )
            )
        }
    }

    /// The projection of the synchronous owner snapshot for this lease and the selected ID.
    func makeProjection() -> PendingLaunchesProjection {
        PendingLaunchesProjection(useCase.snapshot, lease: lease, selectedTaskID: selection?.taskID)
    }

    /// Re-projects from the synchronous owner snapshot, so a result is never judged against a stale copy.
    func reproject() {
        projection = makeProjection()
        pruneStopBookkeeping()
    }

    func didSelectRow(_ id: String) {
        guard didSubscribe, selection == nil, presentation.rows.contains(where: { $0.id == id }) else { return }
        if lease == nil { acquireLease() }
        guard let lease, let bound = useCase.bindSelection(taskID: id, lease: lease) else { return }
        epoch += 1
        selection = bound
        selectedRuntime = useCase.snapshot.runtimeIdentity
        firstCheckSettled = false
        handoffFailed = false
        focusRowID = nil
        detail = .checking(taskID: id)
        enqueueCheck()
        reproject()
        rebuild()
    }

    /// Unbinds synchronously, then shows the inventory with focus on the row that was shown.
    func didTapBack() {
        guard didSubscribe, let shown = selection?.taskID else { return }
        if let lease { _ = useCase.bindSelection(taskID: nil, lease: lease) }
        clearSelection()
        focusRowID = presentation.rows.contains(where: { $0.id == shown }) ? shown : nil
        rebuild()
    }

    func didTapDetailCheckAgain() {
        guard didSubscribe, selection != nil, activeOperations == 0 else { return }
        handoffFailed = false
        // Both not-sent lines clear here. A resolved attempt is acknowledged only if this check stores a fresh lookup.
        stopPrepareNotSent = false
        notSentCleared = true
        let latest = makeProjection().stop?.latest
        enqueueCheck(acknowledging: latest.flatMap { $0.phase.isResolvedOutcome ? $0.attemptID : nil })
        rebuild()
    }

    func didTapCheckTaskStatus() {
        guard didSubscribe, let selection, activeOperations == 0, detail?.action == .checkTaskStatus else { return }
        handoffFailed = false
        let epoch = epoch
        let runtime = selectedRuntime
        enqueue { viewModel in
            guard viewModel.epoch == epoch, viewModel.selection == selection else { return }
            let result = await viewModel.useCase.resolveRecorded(selection: selection)
            viewModel.finishResolve(result, selection: selection, epoch: epoch, runtime: runtime)
        }
        rebuild()
    }

    // MARK: - State

    /// Drops the selected launch and shows the inventory. In-flight owner calls are not cancelled;
    /// their results fail the epoch check.
    func clearSelection() {
        epoch += 1
        selection = nil
        selectedRuntime = nil
        firstCheckSettled = false
        handoffFailed = false
        detail = nil
        discardStopState()
        if projection.stop != nil { projection.stop = nil }
    }

    func resetSelectionForDisappearance() {
        clearSelection()
        focusRowID = nil
        operationSession = UUID()
        activeOperations = 0
    }

    // MARK: - Serialized owner calls

    /// Checks are serialized per lease (the chain restarts with a newly acquired lease): the owner refuses a second check on the same lease while an
    /// earlier call is outstanding, so each operation awaits the previous one without cancelling it.
    /// This is ordering, not retry.
    func enqueue(_ body: @escaping @MainActor (PendingLaunchesVM) async -> Void) {
        let previous = lastOperation
        let session = operationSession
        activeOperations += 1
        lastOperation = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await body(self)
            guard operationSession == session else { return }
            activeOperations -= 1
            rebuild()
        }
    }

    /// Queues one check. `acknowledging` is a resolved Stop attempt that the check hides once it stores a lookup.
    func enqueueCheck(acknowledging attemptID: UUID? = nil) {
        let epoch = epoch
        noteCheckQueued()
        enqueue { viewModel in
            guard viewModel.epoch == epoch, let selection = viewModel.selection else { return }
            let lookup = await viewModel.useCase.check(selection: selection)
            guard viewModel.epoch == epoch, viewModel.selection == selection else { return }
            if let attemptID, lookup.selection == selection, lookup.failure == nil, lookup.value != nil {
                viewModel.acknowledgedAttempts.insert(attemptID)
            }
            viewModel.reproject()
            guard viewModel.selection != nil else { return }
            viewModel.firstCheckSettled = true
        }
    }

    private func finishResolve(_ result: PendingLaunchRecordedResult, selection: PendingLaunchSelection, epoch: Int, runtime: UUID?) {
        guard didSubscribe, self.epoch == epoch, self.selection == selection, useCase.snapshot.runtimeIdentity == runtime else { return }
        reproject()
        guard self.selection != nil else { return }
        firstCheckSettled = true
        switch result {
        case .admitted(let task):
            // Only the exact selected ID, freshly admitted by the owner, may open the task screen.
            if task.taskID == selection.taskID { routing?.openRecordedTask(task.taskID) } else { handoffFailed = true }
        case .failed(let failure):
            switch failure {
            case .changed, .busy, .capacity, .superseded: break // No evidence from this attempt, or the stored lookup already followed.
            default: handoffFailed = true
            }
        }
    }
}
