//
//  SidebarViewRepository.swift
//  MainWindowFeature
//

import Combine
import Foundation
import MonitorCore
import PbRepository
import PbTerminal
import SwiftEnvironment

// MARK: - SidebarViewRepository

/// Concrete `SidebarUseCase` backed by `TaskListRepository` and `TerminalSessionRegistry`.
@MainActor
final class SidebarViewRepository: SidebarUseCase, @unchecked Sendable {
    
    // MARK: - Private Properties
    
    @GlobalEnvironment(\.taskListRepository) private var taskListRepository
    @GlobalEnvironment(\.terminalSessionRegistry) private var terminalSessionRegistry
    
    // MARK: - Init
    
    init(
        taskListRepository: (any TaskListRepository)? = nil,
        terminalSessionRegistry: (any TerminalSessionRegistry)? = nil
    ) {
        if let taskListRepository { self.taskListRepository = taskListRepository }
        if let terminalSessionRegistry { self.terminalSessionRegistry = terminalSessionRegistry }
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
    
    func session(forTask taskID: String) -> TerminalSession? { terminalSessionRegistry.session(forTask: taskID) }
    var interactiveSessions: [TerminalSession] { terminalSessionRegistry.interactiveSessions }
    func sessionsPublisher() -> AnyPublisher<[TerminalSession], Never> { terminalSessionRegistry.sessionsPublisher() }
}
