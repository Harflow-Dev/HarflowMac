//
//  NewSessionVM+Recents.swift
//  MainWindowFeature
//

import Foundation
import HfRepository
import MonitorCore

// MARK: - NewSessionVM + recent repositories

extension NewSessionVM {

    /// How many candidate repositories one existence check covers; more are checked only while fewer than
    /// `recentRepoLimit` exist.
    static let recentRepoBatchSize = 20

    /// The repository popover opened: recheck which recent repositories still exist.
    func didOpenRepositoryPicker() {
        refreshRecentRepos()
    }

    /// Rebuilds the recents off the main actor: distinct repositories newest first, kept only while their
    /// folder still exists (checked in batches until `recentRepoLimit` exist or the candidates run out).
    /// The row stays as it was until the check completes; a superseded or torn-down check publishes nothing.
    func refreshRecentRepos() {
        recentRepoGeneration += 1
        recentRepoTask?.cancel()
        let generation = recentRepoGeneration
        let tasks = useCase.tasks
        recentRepoTask = Task { [weak self, useCase] in
            let candidates = await Self.computeRecentRepoCandidates(tasks)
            var found: [String] = []
            var offset = 0
            while found.count < Self.recentRepoLimit, offset < candidates.count {
                if Task.isCancelled { return }
                let end = min(offset + Self.recentRepoBatchSize, candidates.count)
                let batch = Array(candidates[offset ..< end])
                offset = end
                let existing = await useCase.existingDirectories(among: batch)
                found.append(contentsOf: batch.filter { existing.contains($0) })
            }
            if Task.isCancelled { return }
            let paths = Array(found.prefix(Self.recentRepoLimit))
            guard let self, generation == recentRepoGeneration else { return }
            if paths != recentRepoPaths { recentRepoPaths = paths }
        }
    }

    /// Distinct, non-empty repository paths from the task list, most recent first, with no cap.
    nonisolated static func recentRepoCandidates(_ tasks: [TaskInfo]) -> [String] {
        var seen = Set<String>()
        return tasks
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
            .map(\.repoPath)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    @concurrent private static func computeRecentRepoCandidates(_ tasks: [TaskInfo]) async -> [String] {
        recentRepoCandidates(tasks)
    }
}
