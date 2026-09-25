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

/// Concrete `MenuBarUseCase` backed by `TaskListRepository`, `SettingsRepository` and
/// `EventStreamRepository`.
@MainActor
final class MenuBarViewRepository: MenuBarUseCase, @unchecked Sendable {
    
    // MARK: - Private Properties
    
    @GlobalEnvironment(\.taskListRepository) private var taskListRepository
    @GlobalEnvironment(\.settingsRepository) private var settingsRepository
    @GlobalEnvironment(\.eventStreamRepository) private var eventStreamRepository
    
    // MARK: - Init
    
    init(
        taskListRepository: (any TaskListRepository)? = nil,
        settingsRepository: (any SettingsRepository)? = nil,
        eventStreamRepository: (any EventStreamRepository)? = nil
    ) {
        if let taskListRepository { self.taskListRepository = taskListRepository }
        if let settingsRepository { self.settingsRepository = settingsRepository }
        if let eventStreamRepository { self.eventStreamRepository = eventStreamRepository }
    }
    
    // MARK: - MenuBarUseCase Methods
    
    func tasksPublisher() -> AnyPublisher<[TaskInfo], Never> { taskListRepository.tasksPublisher() }
    func listErrorPublisher() -> AnyPublisher<ToolError?, Never> { taskListRepository.listErrorPublisher() }
    func hasListedPublisher() -> AnyPublisher<Bool, Never> { taskListRepository.hasListedPublisher() }
    func titlesPublisher() -> AnyPublisher<[String: String], Never> { taskListRepository.titlesPublisher() }
    func openWindowOnStartPublisher() -> AnyPublisher<Bool, Never> { settingsRepository.openWindowOnStartPublisher() }
    func notifyOnFinishPublisher() -> AnyPublisher<Bool, Never> { settingsRepository.notifyOnFinishPublisher() }
    
    var openWindowOnStart: Bool { settingsRepository.openWindowOnStart }
    var notifyOnFinish: Bool { settingsRepository.notifyOnFinish }
    var connectionLine: String { taskListRepository.connectionLine }
    var runningCount: Int { taskListRepository.runningCount }
    
    func title(_ taskID: String) -> String { taskListRepository.title(taskID) }
    func setOpenWindowOnStart(_ value: Bool) { settingsRepository.setOpenWindowOnStart(value) }
    func setNotifyOnFinish(_ value: Bool) { settingsRepository.setNotifyOnFinish(value) }
    
    func acquireEventLease(_ taskID: String) -> any EventStreamLease { eventStreamRepository.acquire(taskID) }
    func itemsPublisher(_ taskID: String) -> AnyPublisher<[TimelineItem], Never> { eventStreamRepository.itemsPublisher(for: taskID) }
    func current(_ taskID: String) -> TimelineItem? { eventStreamRepository.current(for: taskID) }
}
