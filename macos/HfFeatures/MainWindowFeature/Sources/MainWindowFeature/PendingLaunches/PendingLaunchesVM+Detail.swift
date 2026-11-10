import Foundation
import HfRepository

// MARK: - Selected launch

extension PendingLaunchesVM {
    var detailInput: PendingLaunchDetailInput? {
        selection.map {
            PendingLaunchDetailInput(
                selection: $0,
                flags: .init(firstCheckSettled: firstCheckSettled, handoffFailed: handoffFailed, isBusy: activeOperations > 0)
            )
        }
    }

    /// Re-projects from the synchronous owner snapshot, so a result is never judged against a stale copy.
    func reproject() {
        projection = PendingLaunchesProjection(useCase.snapshot, lease: lease)
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
        enqueueCheck()
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
    }

    func resetSelectionForDisappearance() {
        clearSelection()
        focusRowID = nil
        operationSession = UUID()
        activeOperations = 0
    }

    // MARK: - Serialized owner calls

    /// Checks are serialized per lease: the owner refuses a second check on the same lease while an
    /// earlier call is outstanding, so each operation awaits the previous one without cancelling it.
    /// This is ordering, not retry.
    private func enqueue(_ body: @escaping @MainActor (PendingLaunchesVM) async -> Void) {
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

    private func enqueueCheck() {
        let epoch = epoch
        enqueue { viewModel in
            guard viewModel.epoch == epoch, let selection = viewModel.selection else { return }
            _ = await viewModel.useCase.check(selection: selection)
            guard viewModel.epoch == epoch, viewModel.selection == selection else { return }
            viewModel.reproject()
            viewModel.firstCheckSettled = true
        }
    }

    private func finishResolve(_ result: PendingLaunchRecordedResult, selection: PendingLaunchSelection, epoch: Int, runtime: UUID?) {
        guard didSubscribe, self.epoch == epoch, self.selection == selection, useCase.snapshot.runtimeIdentity == runtime else { return }
        reproject()
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
