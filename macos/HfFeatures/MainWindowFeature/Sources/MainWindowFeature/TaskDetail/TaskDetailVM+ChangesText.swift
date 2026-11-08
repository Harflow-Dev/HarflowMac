//
//  TaskDetailVM+ChangesText.swift
//  MainWindowFeature
//
//  The second half of the Changes tab: selecting a row, reading its stored patch, the turn picker and the persisted
//  selection. A patch read is bound to (member task id, listing revision, patch generation, selector) and applies only while
//  all four still match. Diff text lives in `changesDiff` alone; it is never logged, described or persisted.
//

import Foundation
import HfRepository
import MonitorCore

// MARK: - Selection

extension TaskDetailVM {

    /// Selects a listed row. A row whose content stores no text is selected and reads nothing.
    func didSelectChangesRow(_ selector: TaskChangesSelector) {
        guard chrome == .standalone, changesLifecycle.rowFacts[selector] != nil, let member = changesLifecycle.memberID else { return }
        let selection = TaskChangesSelection(taskID: member, selector: selector)
        if changesSelection == selection, changesDiff != .none, !isDiffFailure { return }
        changesSelection = selection
        reconcileChangesSelection()
    }

    /// Hands the view model the selection the pane store remembered. It is matched against the loaded listing of its member:
    /// read when the row is there, dropped silently when it is not.
    func restoreChangesSelection(_ selection: TaskChangesSelection?) {
        guard chrome == .standalone, changesSelection == nil, let selection else { return }
        changesSelection = selection
        if changesLifecycle.isDocument { reconcileChangesSelection() }
    }

    /// "Retry": reads the selected row again.
    func didTapRetryChangesDiff() {
        reconcileChangesSelection()
    }

    /// "Reload changes": reads the listing again from the start; the selection was dropped by the failure.
    func didTapReloadChanges() {
        didTapRetryChanges()
    }

    /// Picks a turn of the conversation. It reads that member's listing in a new generation.
    func didSelectChangesTurn(_ taskID: String) {
        guard isMounted, chrome == .standalone, let task, taskID != changesReadMemberID,
              let member = conversationMembers.first(where: { $0.taskID == taskID }) else { return }
        changesLifecycle.selectedTurn = taskID == currentTaskID ? nil : taskID
        let status = taskID == task.taskID ? task.status : member.status
        beginChangesEpoch(member: taskID, status: status, showsLoading: true)
        let picker = TaskChangesTurnPicker.make(memberIDs: conversationMembers.map(\.taskID), selectedID: taskID)
        if changesTurns != picker { changesTurns = picker }
        evaluateChangesDemand()
    }

    // MARK: - Reconciliation

    private var isDiffFailure: Bool {
        if case .failure = changesDiff { true } else { false }
    }

    /// The failure that survives a dropped selection: "Reload changes" has no row to retry. A retryable failure does not,
    /// since its Retry would have nothing to read.
    var isReloadFailure: Bool {
        if case .failure(_, let note) = changesDiff { note.action == .reloadChanges } else { false }
    }

    /// Matches the selection against the applied listing and reads its patch, or drops it. A listing that is not a document
    /// (loading, a note) neither confirms nor refutes the selection, so it stays.
    func reconcileChangesSelection() {
        guard let selection = changesSelection else {
            cancelChangesPatch()
            if changesDiff != .none, !isReloadFailure { changesDiff = .none }
            return
        }
        guard let member = changesLifecycle.memberID else { return }
        guard selection.taskID == member else {
            changesSelection = nil
            cancelChangesPatch()
            if changesDiff != .none, !isReloadFailure { changesDiff = .none }
            return
        }
        guard changesLifecycle.isDocument else {
            cancelChangesPatch()
            if changesDiff != .none { changesDiff = .none }
            return
        }
        guard let facts = changesLifecycle.rowFacts[selection.selector] else {
            changesSelection = nil
            cancelChangesPatch()
            if changesDiff != .none, !isReloadFailure { changesDiff = .none }
            return
        }
        readChangesPatch(selection, facts: facts)
    }

    /// Cancels the outstanding patch read and makes every earlier patch generation stale.
    func cancelChangesPatch() {
        changesPatchTask?.cancel()
        changesPatchTask = nil
        changesLifecycle.patchGeneration &+= 1
        changesPatchFence.advance(to: changesLifecycle.patchGeneration)
    }

    // MARK: - Reading

    private func readChangesPatch(_ selection: TaskChangesSelection, facts: TaskChangesRowFacts) {
        cancelChangesPatch()
        let header = TaskChangesDiffHeader(path: facts.path, scope: facts.scopeTitle)
        guard facts.hasText else {
            let next = TaskChangesDiffPresentation.noText(header, label: facts.label ?? "No stored text")
            if changesDiff != next { changesDiff = next }
            return
        }
        changesDiff = .loading(header)
        let generation = changesLifecycle.patchGeneration
        let revision = changesLifecycle.listingRevision
        let fence = changesPatchFence
        let selector = selection.selector
        changesPatchTask = Task { [weak self, useCase] in
            let key = TaskChangesKey(taskID: selection.taskID, generation: generation)
            // A read superseded while its fence is still current (the runtime changed under it) is repeated once.
            var result = await useCase.readChangesPatch(key: key, selector: selector, operationIsCurrent: { fence.isCurrent(generation) })
            if case .failure(let failed) = result, failed.outcome == .superseded, !Task.isCancelled, fence.isCurrent(generation) {
                result = await useCase.readChangesPatch(key: key, selector: selector, operationIsCurrent: { fence.isCurrent(generation) })
            }
            guard !Task.isCancelled else { return }
            var presentation = TaskChangesDiffPresentation.none
            var failure: TaskChangesDiffBuilder.Failure?
            switch result {
            case .success(let read):
                guard read.key == key else { return }
                let patch = read.value
                let build = Task.detached(priority: .userInitiated) {
                    TaskChangesDiffBuilder.build(patch: patch, header: header, facts: facts)
                }
                presentation = await withTaskCancellationHandler { await build.value } onCancel: { build.cancel() }
            case .failure(let error):
                guard error.key == key else { return }
                let kind = TaskChangesDiffBuilder.classify(error.outcome)
                failure = kind
                presentation = .failure(header, kind.note)
            }
            guard !Task.isCancelled, let self, changesLifecycle.patchGeneration == generation, changesLifecycle.listingRevision == revision,
                  changesLifecycle.memberID == selection.taskID, changesSelection == selection else { return }
            if failure == .reload {
                // The stored changes were replaced: drop the selection and read the listing again from the start.
                changesSelection = nil
                changesDiff = presentation
                if let task {
                    // Fall back to the shown status, as `trackChangesEpoch` does, when the read member no longer resolves.
                    let status = changesReadMemberStatus(task) ?? task.status
                    beginChangesEpoch(member: selection.taskID, status: status, showsLoading: false)
                    evaluateChangesDemand()
                }
            } else if changesDiff != presentation {
                changesDiff = presentation
            }
        }
    }
}
