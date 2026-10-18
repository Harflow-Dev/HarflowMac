//
//  GeneralSettingsViewRepository.swift
//  SettingsFeature
//

import Combine
import Foundation
import MonitorCore
import PbRepository
import SwiftEnvironment

// MARK: - GeneralSettingsViewRepository

/// Concrete `GeneralSettingsUseCase` backed by `SettingsRepository` and `ToolEnvironmentRepository`.
@MainActor
final class GeneralSettingsViewRepository: GeneralSettingsUseCase, @unchecked Sendable {
    
    // MARK: - Private Properties
    
    @GlobalEnvironment(\.settingsRepository) private var settingsRepository
    @GlobalEnvironment(\.toolEnvironmentRepository) private var toolEnvironmentRepository
    @GlobalEnvironment(\.taskListRepository) private var taskListRepository
    @GlobalEnvironment(\.backendsRepository) private var backendsRepository

    // MARK: - Init

    init(
        settingsRepository: (any SettingsRepository)? = nil,
        toolEnvironmentRepository: (any ToolEnvironmentRepository)? = nil,
        taskListRepository: (any TaskListRepository)? = nil,
        backendsRepository: (any BackendsRepository)? = nil
    ) {
        if let settingsRepository { self.settingsRepository = settingsRepository }
        if let toolEnvironmentRepository { self.toolEnvironmentRepository = toolEnvironmentRepository }
        if let taskListRepository { self.taskListRepository = taskListRepository }
        if let backendsRepository { self.backendsRepository = backendsRepository }
    }
    
    // MARK: - GeneralSettingsUseCase Properties
    
    var toolDirectory: String { settingsRepository.toolDirectory }
    var openWindowOnStart: Bool { settingsRepository.openWindowOnStart }
    var notifyOnFinish: Bool { settingsRepository.notifyOnFinish }
    var searchDirectories: [String] { toolEnvironmentRepository.locator.searchDirectories }
    
    // MARK: - GeneralSettingsUseCase Methods
    
    func resolve(_ tool: String) -> ToolResolution {
        switch toolEnvironmentRepository.locator.locate(tool) {
        case .success(let path): .found(path: path)
        case .failure: .notFound
        }
    }
    
    func toolDirectoryPublisher() -> AnyPublisher<String, Never> { settingsRepository.toolDirectoryPublisher() }
    func openWindowOnStartPublisher() -> AnyPublisher<Bool, Never> { settingsRepository.openWindowOnStartPublisher() }
    func notifyOnFinishPublisher() -> AnyPublisher<Bool, Never> { settingsRepository.notifyOnFinishPublisher() }
    
    func tasksPublisher() -> AnyPublisher<[TaskInfo], Never> { taskListRepository.tasksPublisher() }
    func hasListedPublisher() -> AnyPublisher<Bool, Never> { taskListRepository.hasListedPublisher() }
    func listErrorPublisher() -> AnyPublisher<ToolError?, Never> { taskListRepository.listErrorPublisher() }
    
    /// F4-05/decision 11: the write goes through immediately, then triggers a refresh only — the
    /// login-PATH/`uv` probes never rerun (that stays inside `ToolEnvironmentRepository`/
    /// `TaskListRepository`, untouched here).
    func setToolDirectory(_ value: String) {
        settingsRepository.setToolDirectory(value)
        taskListRepository.settingsChanged()
        backendsRepository.settingsChanged()
    }
    
    func setOpenWindowOnStart(_ value: Bool) { settingsRepository.setOpenWindowOnStart(value) }
    func setNotifyOnFinish(_ value: Bool) { settingsRepository.setNotifyOnFinish(value) }
}
