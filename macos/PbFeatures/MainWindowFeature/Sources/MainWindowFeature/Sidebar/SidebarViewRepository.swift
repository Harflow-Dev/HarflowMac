//
//  SidebarViewRepository.swift
//  MainWindowFeature
//

import Combine
import Foundation
import MonitorCore
import PbRepository
import SwiftEnvironment

// MARK: - SidebarViewRepository

/// Concrete `SidebarUseCase` backed by `TaskListRepository`.
@MainActor
final class SidebarViewRepository: SidebarUseCase, SidebarWorkflowUseCase, @unchecked Sendable {
    @GlobalEnvironment(\.workflowRepository) private var workflowRepository

    func workflowSnapshot() async throws -> SidebarWorkflowSnapshot {
        let definitions = try await workflowRepository.command("list", options: [], positionals: [])
        let runs = try await workflowRepository.historySummaries()
        return SidebarWorkflowSnapshot(definitions: WorkflowJSON.objects(definitions["workflows"]), runs: runs)
    }

    // MARK: - Private Properties

    @GlobalEnvironment(\.taskListRepository) private var taskListRepository
    @GlobalEnvironment(\.toolEnvironmentRepository) private var toolEnvironmentRepository
    @GlobalEnvironment(\.installRepository) private var installRepository
    @GlobalEnvironment(\.backendsRepository) private var backendsRepository

    // MARK: - Init

    init(
        taskListRepository: (any TaskListRepository)? = nil,
        toolEnvironmentRepository: (any ToolEnvironmentRepository)? = nil,
        installRepository: (any InstallRepository)? = nil,
        backendsRepository: (any BackendsRepository)? = nil
    ) {
        if let taskListRepository { self.taskListRepository = taskListRepository }
        if let toolEnvironmentRepository { self.toolEnvironmentRepository = toolEnvironmentRepository }
        if let installRepository { self.installRepository = installRepository }
        if let backendsRepository { self.backendsRepository = backendsRepository }
    }

    // MARK: - SidebarUseCase Methods

    func tasksPublisher() -> AnyPublisher<[TaskInfo], Never> { taskListRepository.tasksPublisher() }
    func listErrorPublisher() -> AnyPublisher<ToolError?, Never> { taskListRepository.listErrorPublisher() }
    func hasListedPublisher() -> AnyPublisher<Bool, Never> { taskListRepository.hasListedPublisher() }
    func titlesPublisher() -> AnyPublisher<[String: String], Never> { taskListRepository.titlesPublisher() }

    var tasks: [TaskInfo] { taskListRepository.tasks }
    var listError: ToolError? { taskListRepository.listError }
    var hasListed: Bool { taskListRepository.hasListed }
    var connectionLine: String { taskListRepository.connectionLine }

    func title(_ taskID: String) -> String { taskListRepository.title(taskID) }

    // MARK: Backend catalog (Monitor piece 6)

    var backendCatalog: BackendCatalog { backendsRepository.catalog }
    func backendCatalogPublisher() -> AnyPublisher<BackendCatalog, Never> { backendsRepository.catalogPublisher() }

    // MARK: Install

    func installStatePublisher() -> AnyPublisher<InstallState, Never> { installRepository.statePublisher() }
    var installState: InstallState { installRepository.state }
    func lastCheckMessagePublisher() -> AnyPublisher<String?, Never> { installRepository.lastCheckMessagePublisher() }
    var lastCheckMessage: String? { installRepository.lastCheckMessage }
    func installAnywayBlockedMessagePublisher() -> AnyPublisher<String?, Never> { installRepository.installAnywayBlockedMessagePublisher() }
    var installAnywayBlockedMessage: String? { installRepository.installAnywayBlockedMessage }
    func installDestination() -> String? { installRepository.destination() }
    func install() async { await installRepository.install() }
    func installUvThenPolybridge() async { await installRepository.installUvThenPolybridge() }
    func retry() async { await installRepository.retry() }
    func checkAgain() async { await installRepository.checkAgain() }
    @discardableResult
    func installAnyway() async -> Bool { await installRepository.installAnyway() }
    func reset() { installRepository.reset() }

    func installNeed(for error: ToolError) -> InstallNeed? {
        InstallCommands.installNeed(
            for: error,
            ctl: presence(toolEnvironmentRepository.locator.locate("polybridge-ctl")),
            setup: presence(toolEnvironmentRepository.locator.locate("polybridge-setup"))
        )
    }

    private func presence(_ result: Result<String, ToolError>) -> ToolPresence {
        switch result {
        case .success(let path): .found(path: path)
        case .failure: .notFound
        }
    }
}
