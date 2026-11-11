import Foundation
import HfRepository

// MARK: - ActiveStop

/// A prepared confirmation and what it was captured for. It applies only while all of that is unchanged.
struct ActiveStop {
    let confirmation: PendingLaunchStopConfirmation
    let selection: PendingLaunchSelection
    let runtime: UUID?
    let epoch: Int
}

// MARK: - Stop

extension PendingLaunchesVM {
    /// The Stop button. Inert unless the freshly computed detail offers an enabled Stop: any check, recorded-status call
    /// or preparation in flight disables it, and nothing is queued for later. `prepareStop` runs only from here.
    func didTapStop() {
        guard didSubscribe, let selection, activeOperations == 0, stopIsOffered(for: selection) else { return }
        // A confirmation still held here has no sheet (its callback was lost): replace it, never block on it.
        if stopConfirmation != nil {
            let cleared = notSentCleared
            discardStopState()
            notSentCleared = cleared
        }
        stopPrepareNotSent = false
        let epoch = epoch
        let runtime = selectedRuntime
        enqueue { viewModel in
            guard viewModel.epoch == epoch, viewModel.selection == selection else { return }
            let result = await viewModel.useCase.prepareStop(selection: selection)
            viewModel.finishPrepare(result, selection: selection, epoch: epoch, runtime: runtime)
        }
        rebuild()
    }

    /// Request Stop. Submits once; the owner owns the command from here and nothing is ever retried.
    func confirmStop(id: UUID) {
        guard didSubscribe, let active = stopConfirmation, active.confirmation.id == id, isCurrent(active) else { return }
        stopConfirmation = nil
        switch useCase.submitStop(confirmation: active.confirmation) {
        case .submitted, .existing:
            notSentCleared = false
            dismissFocusID = id
            focusTitleAfterDismiss = true
            reproject()
        case .refused(.changed):
            // Best effort: the focus request lands only if Stop is enabled when the native dismissal arrives, and the
            // refresh check queued below is usually still running then.
            dismissFocusID = id
            focusStopAfterDismiss = true
            enqueueCheck()
        case .refused:
            stopPrepareNotSent = true
            dismissFocusID = id
            focusStopAfterDismiss = true
        }
        rebuild()
    }

    /// Ends the confirmation without a request. Ignored unless it is the active one, so a late callback for an earlier
    /// sheet cannot touch a newer one.
    func cancelStop(id: UUID, reason: PendingLaunchStopCancelReason) {
        guard let active = stopConfirmation, active.confirmation.id == id, isCurrent(active) else { return }
        stopConfirmation = nil
        dismissFocusID = id
        focusStopAfterDismiss = reason == .userCancel
    }

    /// Called from the sheet's native dismissal for `id`: Stop after a user cancel, the card title after Request Stop.
    /// A dismissal of any other confirmation leaves a newer request's focus untouched.
    func stopSheetDidDismiss(id: UUID) {
        guard dismissFocusID == id else { return }
        defer { dismissFocusID = nil; focusStopAfterDismiss = false; focusTitleAfterDismiss = false }
        guard didSubscribe, selection != nil else { return }
        if focusStopAfterDismiss { stopFocusRequest += 1 }
        if focusTitleAfterDismiss { titleFocusRequest += 1 }
    }

    // MARK: - Preparation

    /// Whether the synchronous projection of the selected launch offers an enabled Stop right now.
    private func stopIsOffered(for selection: PendingLaunchSelection) -> Bool {
        let fresh = makeProjection()
        let detail = PendingLaunchDetailPresentation.make(
            lookup: fresh.lookup, input: PendingLaunchDetailInput(selection: selection, flags: stopFlags(fresh)),
            stop: fresh.stop, runtimeKnown: fresh.runtimeKnown
        )
        return detail.stop == .enabled
    }

    private func stopFlags(_ fresh: PendingLaunchesProjection) -> PendingLaunchDetailFlags {
        .init(firstCheckSettled: firstCheckSettled, handoffFailed: handoffFailed, isBusy: activeOperations > 0,
              stopPrepareNotSent: stopPrepareNotSent,
              acknowledgedAttempt: fresh.stop.map { acknowledgedAttempts.contains($0.latest.attemptID) } ?? false,
              notSentCleared: notSentCleared)
    }

    private func finishPrepare(_ result: PendingLaunchStopPreparation, selection: PendingLaunchSelection, epoch: Int, runtime: UUID?) {
        guard didSubscribe, self.epoch == epoch, self.selection == selection, useCase.snapshot.runtimeIdentity == runtime else { return }
        reproject()
        guard self.selection != nil else { return }
        firstCheckSettled = true
        switch result {
        case .confirmation(let confirmation):
            // Eligibility is read from the reprojected lookup with the pure mapping; the async detail is never consulted.
            guard stillOffers(confirmation, selection: selection) else { return }
            stopConfirmation = ActiveStop(confirmation: confirmation, selection: selection, runtime: runtime, epoch: epoch)
            routing?.presentPendingLaunchStop(PendingLaunchStopRequest(
                id: confirmation.id, taskID: confirmation.taskID,
                confirm: { [weak self] in self?.confirmStop(id: confirmation.id) },
                cancel: { [weak self] in self?.cancelStop(id: confirmation.id, reason: $0) },
                didDismiss: { [weak self] in self?.stopSheetDidDismiss(id: $0) }
            ))
        case .failed(let failure):
            switch failure {
            // The preparation's own read stored the fresh lookup, which now shows what changed.
            case .changed, .recorded, .unsupported, .superseded: break
            default: stopPrepareNotSent = true
            }
        }
    }

    private func stillOffers(_ confirmation: PendingLaunchStopConfirmation, selection: PendingLaunchSelection) -> Bool {
        guard confirmation.taskID == selection.taskID, let lookup = projection.lookup, lookup.selection == selection,
              lookup.failure == nil, let item = lookup.value?.item, item.disposition == .pending,
              let generation = item.launch?.generation, generation == confirmation.generation,
              PendingLaunchDetailPresentation.stopEligibility(item: item, runtimeKnown: projection.runtimeKnown) else { return false }
        return projection.stop?.unsafeGenerations.contains(generation) != true
    }

    private func isCurrent(_ active: ActiveStop) -> Bool {
        active.epoch == epoch && selection == active.selection && selectedRuntime == active.runtime
    }

    // MARK: - Bookkeeping

    /// Drops the confirmation and the not-sent lines, and closes the sheet if one is shown. Attempts are untouched.
    func discardStopState() {
        let hadConfirmation = stopConfirmation != nil
        stopConfirmation = nil
        stopPrepareNotSent = false
        notSentCleared = false
        dismissFocusID = nil
        focusStopAfterDismiss = false
        focusTitleAfterDismiss = false
        if hadConfirmation { routing?.dismissPendingLaunchStop() }
    }

    /// Acknowledgements and refresh marks follow the attempts still held by the owner.
    func pruneStopBookkeeping() {
        guard !acknowledgedAttempts.isEmpty || !refreshedPreflightAttempts.isEmpty else { return }
        let held = Set(useCase.snapshot.attempts.map(\.id))
        acknowledgedAttempts.formIntersection(held)
        refreshedPreflightAttempts.formIntersection(held)
    }

    /// A check queued after an attempt is visible as "preflight changed" is that attempt's refresh.
    func noteCheckQueued() {
        if let latest = makeProjection().stop?.latest, latest.phase == .preflightChanged {
            refreshedPreflightAttempts.insert(latest.attemptID)
        }
    }

    /// One read, never a Stop: the launch changed between confirmation and send, so the stored lookup is stale.
    func queuePreflightRefreshIfNeeded() {
        guard didSubscribe, selection != nil, let latest = projection.stop?.latest, latest.phase == .preflightChanged,
              !refreshedPreflightAttempts.contains(latest.attemptID) else { return }
        enqueueCheck()
    }
}
