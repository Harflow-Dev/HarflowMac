//
//  NewSessionViewRepository.swift
//  MainWindowFeature
//

import Combine
import Foundation
import MonitorCore
import PbRepository
import SwiftEnvironment

// MARK: - NewSessionViewRepository

/// Concrete `NewSessionUseCase` backed by `TaskActionRepository`, `BackendsRepository` and
/// `TaskListRepository` (for the "Recent" repositories) and `ModelCatalogRepository`.
@MainActor
final class NewSessionViewRepository: NewSessionUseCase, @unchecked Sendable {

    // MARK: - Private Properties

    @GlobalEnvironment(\.taskActionRepository) private var taskActionRepository
    @GlobalEnvironment(\.backendsRepository) private var backendsRepository
    @GlobalEnvironment(\.taskListRepository) private var taskListRepository
    @GlobalEnvironment(\.modelCatalogRepository) private var modelCatalogRepository

    // MARK: - Init

    init(
        taskActionRepository: (any TaskActionRepository)? = nil,
        backendsRepository: (any BackendsRepository)? = nil,
        taskListRepository: (any TaskListRepository)? = nil,
        modelCatalogRepository: (any ModelCatalogRepository)? = nil
    ) {
        if let taskListRepository { self.taskListRepository = taskListRepository }
        if let taskActionRepository { self.taskActionRepository = taskActionRepository }
        if let backendsRepository { self.backendsRepository = backendsRepository }
        if let modelCatalogRepository { self.modelCatalogRepository = modelCatalogRepository }
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

    var tasks: [TaskInfo] { taskListRepository.tasks }

    // MARK: Backend catalog (Monitor piece 6)

    var backendCatalog: BackendCatalog { backendsRepository.catalog }
    func backendCatalogPublisher() -> AnyPublisher<BackendCatalog, Never> { backendsRepository.catalogPublisher() }

    // MARK: Model catalog

    func models(for backend: String) async -> [ModelOption] { await modelCatalogRepository.models(for: backend) }
}
