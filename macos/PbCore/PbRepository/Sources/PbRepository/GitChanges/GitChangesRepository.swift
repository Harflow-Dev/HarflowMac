import Foundation
import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - GitChangesRepository

/// A stateless wrapper over `GitInspector` (`TaskDetailView.swift:122-123`). The git-generation
/// guard and the 10 s running-only poll stay in `MainWindowFeature.TaskDetailVM` (decision 8) — this
/// repository only answers one question at a time.
@Mockable
public protocol GitChangesRepository: Sendable {
    func changes(repo: String, baseCommit: String?, startDirty: Bool?, environment: [String: String]) async -> GitChanges
}

// MARK: - GitChangesRepositoryImpl

public struct GitChangesRepositoryImpl: GitChangesRepository {
    private let runner: ProcessRunning

    public init(runner: ProcessRunning = ProcessRunner()) {
        self.runner = runner
    }

    public func changes(repo: String, baseCommit: String?, startDirty: Bool?, environment: [String: String]) async -> GitChanges {
        await GitInspector(environment: environment, runner: runner).changes(repo: repo, baseCommit: baseCommit, startDirty: startDirty)
    }
}

// MARK: - NullGitChangesRepository

public struct NullGitChangesRepository: GitChangesRepository {
    public init() {}
    public func changes(repo _: String, baseCommit _: String?, startDirty _: Bool?, environment _: [String: String]) async -> GitChanges {
        GitChanges(files: [], diffs: [], commitsSinceBase: nil, branch: nil, labels: [], comparedWithBase: false)
    }
}

// MARK: - GlobalValues

public extension GlobalValues {

    /// Global git-changes repository.
    @GlobalEntry var gitChangesRepository: any GitChangesRepository = NullGitChangesRepository()
}
