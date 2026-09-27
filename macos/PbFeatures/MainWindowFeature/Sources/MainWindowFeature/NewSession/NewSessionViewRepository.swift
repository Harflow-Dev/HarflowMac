//
//  NewSessionViewRepository.swift
//  MainWindowFeature
//

import Foundation
import MonitorCore
import PbRepository
import SwiftEnvironment

// MARK: - NewSessionViewRepository

/// Concrete `NewSessionUseCase` backed by `TaskActionRepository`.
@MainActor
final class NewSessionViewRepository: NewSessionUseCase, @unchecked Sendable {

    // MARK: - Private Properties

    @GlobalEnvironment(\.taskActionRepository) private var taskActionRepository

    // MARK: - Init

    init(taskActionRepository: (any TaskActionRepository)? = nil) {
        if let taskActionRepository { self.taskActionRepository = taskActionRepository }
    }

    // MARK: - NewSessionUseCase Methods

    /// Ported verbatim from the old `NewSessionSheet.start()` (`MainView.swift:144-150`): expand
    /// `~`, then require an absolute path to an existing directory.
    func resolvedRepoPath(_ input: String) -> String? {
        let path = (input as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return path
    }

    func run(_ request: RunRequest) async throws -> String {
        try await taskActionRepository.run(request)
    }
}
