//
//  TaskDetailVM+Changes.swift
//  MainWindowFeature
//
//  Reads the shown member's stored repository changes for the standalone Changes tab. A read starts only while the
//  screen is on and something needs the answer: the pane is open, or a capture is settling. Each read gets a new
//  generation; the repository's fence and the main-actor check below drop anything older. The presentation is built
//  off the main actor and applied only when it differs from what is shown.
//

import Foundation
import HfRepository
import MonitorCore

// MARK: - Demand and triggers

extension TaskDetailVM {

    /// The view reports whether the pane is open. The first report after the screen appears counts as a change.
    func setChangesPaneOpen(_ open: Bool) {
        guard changesLifecycle.paneOpen != open else { return }
        changesLifecycle.paneOpen = open
        evaluateChangesDemand()
    }

    /// Whether anything needs the stored changes right now. Group and embedded mounts never read.
    var changesHasDemand: Bool {
        guard isMounted, chrome == .standalone, let task else { return false }
        if changesLifecycle.paneOpen == true { return true }
        // A capture that is settling keeps being read with the pane closed, until a non-settling answer or the cap.
        if changesLifecycle.appliedSettling { return true }
        return task.status.isTerminal && observationFrames[currentTaskID]?.logState == .settling
    }

    /// Reads when a read is owed and there is demand; otherwise leaves the epoch stale for the next demand.
    func evaluateChangesDemand() {
        guard changesLifecycle.needsRead, changesHasDemand else { return }
        startChangesRead()
    }

    /// A new epoch starts when the member changes, and a stale one when its shown status or the conversation's member set changes. Both cancel what is in
    /// flight and the cadence, start a fresh cap, and owe a read.
    func trackChangesEpoch(_ detail: TaskInfo) {
        guard chrome == .standalone else { return }
        if changesLifecycle.memberID != detail.taskID {
            beginChangesEpoch(member: detail.taskID, status: detail.status, showsLoading: true)
        } else if changesLifecycle.shownStatus != detail.status || changesLifecycle.memberIDs != conversationMembers.map(\.taskID) {
            beginChangesEpoch(member: detail.taskID, status: detail.status, showsLoading: false)
        }
    }

    /// "Retry read" and "Check again": a new epoch that reads at once.
    func didTapRetryChanges() {
        guard isMounted, chrome == .standalone, let task else { return }
        beginChangesEpoch(member: task.taskID, status: task.status, showsLoading: true)
        startChangesRead()
    }

    /// Reveals the next step of a scope's rows from the snapshot already read.
    func didTapLoadMoreChangeRows(scope: TaskChangesScopeID) {
        changesRevealLimits[scope] = (changesRevealLimits[scope] ?? TaskChangesPresentationBuilder.revealStep)
            + TaskChangesPresentationBuilder.revealStep
    }

    /// Drops every piece of changes state. `didDisappear` also forgets the view's pane report, so the first report after
    /// reappearing counts as a change; a missing task keeps it, since the view is still there.
    func resetChanges(keepPaneReport: Bool) {
        cancelChangesWork()
        let paneOpen = keepPaneReport ? changesLifecycle.paneOpen : nil
        let generation = changesLifecycle.generation
        changesLifecycle = TaskChangesLifecycle()
        changesLifecycle.generation = generation
        changesLifecycle.paneOpen = paneOpen
        if changesPresentation != .loading { changesPresentation = .loading }
        if changesTabCount != nil { changesTabCount = nil }
        if changesCaptureSettling { changesCaptureSettling = false }
        if !changesRevealLimits.isEmpty { changesRevealLimits = [:] }
    }

    // MARK: - Epochs

    private func beginChangesEpoch(member: String, status: TaskStatus, showsLoading: Bool) {
        cancelChangesWork()
        changesLifecycle.memberID = member
        changesLifecycle.shownStatus = status
        changesLifecycle.memberIDs = conversationMembers.map(\.taskID)
        changesLifecycle.needsRead = true
        changesLifecycle.settlingSince = nil
        changesLifecycle.settlingResults = 0
        changesLifecycle.capped = false
        changesLifecycle.supersededRetries = 0
        if changesTabCount != nil { changesTabCount = nil }
        if changesCaptureSettling { changesCaptureSettling = false }
        if showsLoading {
            changesLifecycle.appliedSettling = false
            if changesPresentation != .loading { changesPresentation = .loading }
            if !changesRevealLimits.isEmpty { changesRevealLimits = [:] }
        }
    }

    /// Cancels the read and the cadence and makes every earlier generation stale.
    private func cancelChangesWork() {
        changesReadTask?.cancel()
        changesReadTask = nil
        changesCadenceTask?.cancel()
        changesCadenceTask = nil
        changesLifecycle.generation &+= 1
        changesFence.advance(to: changesLifecycle.generation)
    }

    // MARK: - Reading

    /// Starts one listing read in a new generation. The presentation on screen stays until the result applies.
    private func startChangesRead() {
        changesReadTask?.cancel()
        changesCadenceTask?.cancel()
        changesCadenceTask = nil
        changesLifecycle.generation &+= 1
        let generation = changesLifecycle.generation
        changesFence.advance(to: generation)
        changesLifecycle.needsRead = false
        if changesTabCount != nil { changesTabCount = nil }
        let member = changesLifecycle.memberID ?? currentTaskID
        let fence = changesFence
        changesReadTask = Task { [weak self, useCase] in
            let key = TaskChangesKey(taskID: member, generation: generation)
            let result = await useCase.readChanges(key: key, operationIsCurrent: { fence.isCurrent(generation) })
            guard !Task.isCancelled else { return }
            let outcome: TaskChangesReadOutcome
            switch result {
            case .success(let read):
                guard read.key == key else { return }
                outcome = .snapshot(read.value)
            case .failure(let failure):
                guard failure.key == key else { return }
                outcome = .failure(failure.outcome)
            }
            let built = await Task.detached(priority: .userInitiated) {
                TaskChangesPresentationBuilder.build(taskID: member, outcome: outcome)
            }.value
            guard !Task.isCancelled, let self, changesLifecycle.generation == generation,
                  changesLifecycle.memberID == member else { return }
            applyChanges(built, generation: generation)
        }
    }

    /// Applies a built result of the current generation, writing only the fields that changed.
    private func applyChanges(_ result: TaskChangesBuilt, generation: UInt64) {
        var built = result
        if built.wasSuperseded {
            // The runtime changed under the read. Read once more; a second supersession is shown as unavailable.
            if changesLifecycle.supersededRetries < 1 {
                changesLifecycle.supersededRetries += 1
                if changesHasDemand { startChangesRead() } else { changesLifecycle.needsRead = true }
                return
            }
            built = TaskChangesBuilt(presentation: .note(TaskChangesFailure.unavailable.note), tabCount: nil, isSettling: false,
                                     wasSuperseded: false)
        }
        changesLifecycle.supersededRetries = 0
        // The cap is decided before the first write, so a capped result is written once.
        let deadline = built.isSettling ? registerSettlingResult() : nil
        let presentation = deadline?.isCapped == true ? TaskChangesPresentation.settlingCapped : built.presentation
        if changesPresentation != presentation { changesPresentation = presentation }
        if changesTabCount != built.tabCount { changesTabCount = built.tabCount }
        if changesCaptureSettling != built.isSettling { changesCaptureSettling = built.isSettling }
        changesLifecycle.appliedSettling = built.isSettling
        if let deadline {
            if !deadline.isCapped { scheduleSettlingRead(generation: generation, since: deadline.since, remaining: deadline.remaining) }
        } else {
            changesLifecycle.settlingSince = nil
            changesLifecycle.settlingResults = 0
            changesLifecycle.capped = false
        }
    }

    // MARK: - Settling cadence

    /// Counts one more settling result and reports where the 5 minute cap stands.
    private func registerSettlingResult() -> (since: Date, remaining: TimeInterval, isCapped: Bool) {
        let now = scheduler.now()
        let since = changesLifecycle.settlingSince ?? now
        changesLifecycle.settlingSince = since
        changesLifecycle.settlingResults += 1
        let remaining = TaskChangesLifecycle.settlingCap - now.timeIntervalSince(since)
        changesLifecycle.capped = remaining <= 0
        return (since, remaining, remaining <= 0)
    }

    /// Schedules the next read of a settling capture from the result just applied, so reads never overlap: 5 seconds
    /// after the first settling result, then every 15, each wait bounded by the time left before the cap. At the cap
    /// nothing more is read: the pane shows "Check again" without another response. The cadence only repeats a
    /// presentation read; it changes nothing the engine does.
    private func scheduleSettlingRead(generation: UInt64, since: Date, remaining: TimeInterval) {
        let step = changesLifecycle.settlingResults == 1 ? TaskChangesLifecycle.firstSettlingDelay : TaskChangesLifecycle.settlingDelay
        let delay = min(step, remaining)
        changesCadenceTask = Task { [weak self, scheduler] in
            do { try await scheduler.wait(for: delay) } catch { return }
            guard !Task.isCancelled, let self, changesLifecycle.generation == generation, isMounted else { return }
            // The cap is checked again at wake: a wake after sleep can land past the deadline.
            guard scheduler.now().timeIntervalSince(since) < TaskChangesLifecycle.settlingCap else {
                changesLifecycle.capped = true
                if changesPresentation != .settlingCapped { changesPresentation = .settlingCapped }
                return
            }
            startChangesRead()
        }
    }
}
