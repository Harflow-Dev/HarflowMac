//
//  MenuBarViewRepository.swift
//  MenuBarFeature
//

import Combine
import Foundation
import MonitorCore
import PbRepository
import SwiftEnvironment

// MARK: - MenuBarViewRepository

/// Concrete `MenuBarUseCase` backed by `TaskListRepository` and `EventStreamRepository`.
@MainActor
final class MenuBarViewRepository: MenuBarUseCase, MenuBarCountAvailabilityUseCase, @unchecked Sendable {
    
    // MARK: - Private Properties
    
    @GlobalEnvironment(\.taskListRepository) private var taskListRepository
    @GlobalEnvironment(\.eventStreamRepository) private var eventStreamRepository
    @GlobalEnvironment(\.toolEnvironmentRepository) private var toolEnvironmentRepository
    @GlobalEnvironment(\.installRepository) private var installRepository

    // MARK: - Init

    init(
        taskListRepository: (any TaskListRepository)? = nil,
        eventStreamRepository: (any EventStreamRepository)? = nil,
        toolEnvironmentRepository: (any ToolEnvironmentRepository)? = nil,
        installRepository: (any InstallRepository)? = nil
    ) {
        if let taskListRepository { self.taskListRepository = taskListRepository }
        if let eventStreamRepository { self.eventStreamRepository = eventStreamRepository }
        if let toolEnvironmentRepository { self.toolEnvironmentRepository = toolEnvironmentRepository }
        if let installRepository { self.installRepository = installRepository }
    }
    
    // MARK: - MenuBarUseCase Methods
    
    func tasksPublisher() -> AnyPublisher<[TaskInfo], Never> { taskListRepository.tasksPublisher() }
    func listErrorPublisher() -> AnyPublisher<ToolError?, Never> { taskListRepository.listErrorPublisher() }
    func hasListedPublisher() -> AnyPublisher<Bool, Never> { taskListRepository.hasListedPublisher() }
    func titlesPublisher() -> AnyPublisher<[String: String], Never> { taskListRepository.titlesPublisher() }
    
    var connectionLine: String { taskListRepository.connectionLine }
    var countsComplete: Bool { taskListRepository.historyState.countsComplete }
    var runningCount: Int { taskListRepository.runningCount }
    
    func title(_ taskID: String) -> String { taskListRepository.title(taskID) }
    
    func acquireEventLease(_ taskID: String) -> any EventStreamLease { eventStreamRepository.acquire(taskID) }
    func itemsPublisher(_ taskID: String) -> AnyPublisher<[TimelineItem], Never> { eventStreamRepository.itemsPublisher(for: taskID) }
    func current(_ taskID: String) -> TimelineItem? { eventStreamRepository.current(for: taskID) }

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
