//
//  NewSessionViewRepository.swift
//  MainWindowFeature
//

import Combine
import Foundation
import HfRepository
import MonitorCore
import SwiftEnvironment

// MARK: - NewSessionViewRepository

/// Concrete `NewSessionUseCase` backed by `TaskActionRepository`, `BackendsRepository` and
/// `TaskListRepository` (for the "Recent" repositories) and `ModelCatalogRepository`.
@MainActor
final class NewSessionViewRepository: NewSessionUseCase, @unchecked Sendable {

    // MARK: - Private Properties

    @GlobalEnvironment(\.qualificationRepository) private var qualificationRepository
    func qualificationSession() -> QualificationSession { QualificationSession(repository: qualificationRepository) }

    @GlobalEnvironment(\.taskActionRepository) private var taskActionRepository
    @GlobalEnvironment(\.backendsRepository) private var backendsRepository
    @GlobalEnvironment(\.taskListRepository) private var taskListRepository
    @GlobalEnvironment(\.modelCatalogRepository) private var modelCatalogRepository
    @GlobalEnvironment(\.agentUsageRepository) private var agentUsageRepository

    // MARK: - Init

    init(
        taskActionRepository: (any TaskActionRepository)? = nil,
        backendsRepository: (any BackendsRepository)? = nil,
        taskListRepository: (any TaskListRepository)? = nil,
        modelCatalogRepository: (any ModelCatalogRepository)? = nil,
        agentUsageRepository: (any AgentUsageRepository)? = nil
    ) {
        if let taskListRepository { self.taskListRepository = taskListRepository }
        if let taskActionRepository { self.taskActionRepository = taskActionRepository }
        if let backendsRepository { self.backendsRepository = backendsRepository }
        if let modelCatalogRepository { self.modelCatalogRepository = modelCatalogRepository }
        if let agentUsageRepository { self.agentUsageRepository = agentUsageRepository }
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

    func run(_ request: RunRequest, runtime: QualificationRuntimeToken) async throws -> String {
        let identity = AgentUsageIdentity(backend: request.backend, model: request.model)
        let id = try await taskActionRepository.run(request, runtime: runtime)
        if !id.isEmpty { await agentUsageRepository.record(identity, acknowledgementID: "task:" + id) }
        return id
    }

    var agentUsageSnapshot: AgentUsageSnapshot { agentUsageRepository.snapshot }
    func agentUsagePublisher() -> AnyPublisher<AgentUsageSnapshot, Never> { agentUsageRepository.snapshotPublisher() }

    var tasks: [TaskInfo] { taskListRepository.tasks }

    // MARK: Backend catalog (Monitor piece 6)

    var backendCatalog: BackendCatalog { backendsRepository.catalog }
    func backendCatalogPublisher() -> AnyPublisher<BackendCatalog, Never> { backendsRepository.catalogPublisher() }

    // MARK: Model catalog

    func models(for backend: String) async -> [ModelOption] { await modelCatalogRepository.models(for: backend) }
}
