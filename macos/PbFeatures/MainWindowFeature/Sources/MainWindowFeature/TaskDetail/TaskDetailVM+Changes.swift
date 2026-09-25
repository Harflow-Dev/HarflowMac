//
//  TaskDetailVM+Changes.swift
//  MainWindowFeature
//
//  Git: the generation guard and the 10 s running-only poll (decision 8), restarting whenever the
//  task's status changes (`TaskDetailView.swift:74-82,108-126`). `GitChangesRepository` stays
//  stateless; everything here is the VM's own bookkeeping.
//
//  The poll is SEQUENTIAL, matching the original `TaskDetailView.swift:74-81`: load, then — only
//  once that load has finished — wait 10 s and load again, for as long as the task keeps running.
//  A repeating timer would instead re-fire every 10 s regardless of how long a load takes, so a
//  load slower than 10 s is superseded by the next tick's generation bump before it can ever
//  publish. `gitPollGeneration` guards the recursive chain the same way `changesGeneration` guards
//  a single `loadChanges()` call: cancelling the poll (a status change or `didDisappear()`) bumps
//  it, so a `schedule(after:)` callback already in flight from a superseded poll is a no-op.
//

import Foundation
import MonitorCore
import PbRepository

extension TaskDetailVM {
    
    /// Restarts the git flow only when the status actually changed (not on every recompute), and
    /// only while there is a repo to check — an empty `repoPath` skips git entirely.
    func handleTaskUpdateForGit(_ task: TaskInfo) {
        guard !task.repoPath.isEmpty else { return }
        guard task.status != lastGitStatus else { return }
        cancelGitPoll()
        // After the cancel, which resets `lastGitStatus` for a later reappear.
        lastGitStatus = task.status
        let generation = gitPollGeneration
        Task { [weak self] in await self?.runGitPollCycle(generation: generation) }
    }
    
    /// Loads once, then — only after that load has completed, and only while the task is still
    /// running and this poll has not been cancelled or superseded — schedules exactly one further
    /// cycle 10 s later. Never a repeating timer: see the file header for why.
    func runGitPollCycle(generation: Int) async {
        await loadChanges()
        guard generation == gitPollGeneration else { return }
        guard let task, task.status.isRunning else { return }
        gitPollCancellable = useCase.schedule(after: 10) { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.gitPollGeneration else { return }
                await self.runGitPollCycle(generation: generation)
            }
        }
    }
    
    func cancelGitPoll() {
        gitPollCancellable?.cancel()
        gitPollCancellable = nil
        lastGitStatus = nil
        gitPollGeneration += 1
        // Also invalidates a load still waiting on its snapshot or git, as the original's `.task`
        // cancellation did: it then stops at its next generation check instead of publishing.
        changesGeneration += 1
    }
    
    /// The baseline (`base_commit`, `start_dirty`) is only in the snapshot, never in a listing, so
    /// git is not asked until the snapshot is in hand.
    func loadChanges() async {
        guard let task, !task.repoPath.isEmpty else { return }
        changesGeneration += 1
        let generation = changesGeneration
        if useCase.snapshot(taskID) == nil { await useCase.refreshSnapshot(taskID) }
        guard generation == changesGeneration else { return }
        guard let snapshot = useCase.snapshot(taskID) else {
            // `changesError` is set, but stale `changes` are kept — never cleared on failure.
            changesError = "The task's baseline could not be read (polybridge-ctl status failed), so its changes are not shown."
            let current = self.task ?? task
            recomputeChanges(task: current)
            recomputeInspector(task: current, ancestors: useCase.ancestors(of: taskID))
            return
        }
        let result = await useCase.gitChanges(repo: task.repoPath, baseCommit: snapshot.baseCommit, startDirty: snapshot.startDirty)
        guard generation == changesGeneration else { return }
        changesError = nil
        changes = result
        // The task may have been republished during the awaits; rebuild from the current value.
        let current = self.task ?? task
        recomputeChanges(task: current)
        // The Inspector reads the same `changes` the Changes pane does (both panes shared one
        // `changes` in the original) — a git result outside a full `recompute()` pass (the poll, a
        // manual reload) must refresh it too, or it goes stale.
        recomputeInspector(task: current, ancestors: useCase.ancestors(of: taskID))
    }
    
    func recomputeChanges(task: TaskInfo) {
        changesFileCount = changes?.files.count ?? 0
        let summary = task.status.isTerminal ? (useCase.snapshot(taskID)?.summary ?? task.summary) : nil
        changesModel = ChangesPaneModel(
            changes: changes,
            error: changesError,
            commands: Timeline.commands(in: latestItems),
            summary: (summary?.isEmpty == false) ? summary : nil,
            onReload: { [weak self] in self?.didTapReloadChanges() },
            previewFile: { [weak self] path in
                guard let self else { return .unreadable }
                return await previewFile(path: path)
            }
        )
    }
    
    func previewFile(path: String) async -> FilePreviewResult {
        guard let task else { return .unreadable }
        return await useCase.previewFile(repo: task.repoPath, path: path)
    }
}
