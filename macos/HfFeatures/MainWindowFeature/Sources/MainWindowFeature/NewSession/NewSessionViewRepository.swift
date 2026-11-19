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
        return Self.isAbsoluteDirectory(path) ? path : nil
    }

    func run(_ request: RunRequest, runtime: QualificationRuntimeToken) async throws -> String {
        let identity = AgentUsageIdentity(backend: request.backend, model: request.model)
        let id = try await taskActionRepository.run(request, runtime: runtime)
        if !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { await agentUsageRepository.record(identity, acknowledgementID: "task:" + id) }
        return id
    }

    var agentUsageSnapshot: AgentUsageSnapshot { agentUsageRepository.snapshot }
    func agentUsagePublisher() -> AnyPublisher<AgentUsageSnapshot, Never> { agentUsageRepository.snapshotPublisher() }

    var tasks: [TaskInfo] { taskListRepository.tasks }

    func existingDirectories(among paths: [String]) async -> Set<String> {
        await Self.existingDirectoryPaths(among: paths)
    }

    /// Keeps the absolute paths that exist and are directories, checking cancellation between paths.
    /// Not main-actor: `FileManager` calls do disk I/O.
    @concurrent private static func existingDirectoryPaths(among paths: [String]) async -> Set<String> {
        var existing = Set<String>()
        for path in paths {
            if Task.isCancelled { break }
            if Self.isAbsoluteDirectory(path) { existing.insert(path) }
        }
        return existing
    }

    private nonisolated static func isAbsoluteDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: Backend catalog (Monitor piece 6)

    var backendCatalog: BackendCatalog { backendsRepository.catalog }
    func backendCatalogPublisher() -> AnyPublisher<BackendCatalog, Never> { backendsRepository.catalogPublisher() }

    // MARK: Model catalog

    func modelListing(for backend: String) async -> ModelListing { await modelCatalogRepository.listing(for: backend) }
    func refreshModelListing(for backend: String) async -> ModelListing { await modelCatalogRepository.refreshListing(for: backend) }
}
