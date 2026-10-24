//
//  GeneralSettingsViewRepository.swift
//  SettingsFeature
//

import Combine
import Foundation
import HfRepository
import MonitorCore
import SwiftEnvironment

// MARK: - GeneralSettingsViewRepository

/// Concrete `GeneralSettingsUseCase` backed by `SettingsRepository` and `ToolEnvironmentRepository`.
@MainActor
final class GeneralSettingsViewRepository: GeneralSettingsUseCase, RuntimeSetupObserving, StoreRecoveryUseCase, @unchecked Sendable {
    
    // MARK: - Private Properties
    
    @GlobalEnvironment(\.stateRecoveryRepository) private var stateRecoveryRepository
    @GlobalEnvironment(\.installRepository) private var installRepository
    @GlobalEnvironment(\.settingsRepository) private var settingsRepository
    @GlobalEnvironment(\.toolEnvironmentRepository) private var toolEnvironmentRepository
    @GlobalEnvironment(\.taskListRepository) private var taskListRepository
    @GlobalEnvironment(\.backendsRepository) private var backendsRepository

    // MARK: - Init

    init(
        settingsRepository: (any SettingsRepository)? = nil,
        toolEnvironmentRepository: (any ToolEnvironmentRepository)? = nil,
        taskListRepository: (any TaskListRepository)? = nil,
        backendsRepository: (any BackendsRepository)? = nil,
        installRepository: (any InstallRepository)? = nil,
        stateRecoveryRepository: (any StateRecoveryRepository)? = nil
    ) {
        if let stateRecoveryRepository { self.stateRecoveryRepository = stateRecoveryRepository }
        if let installRepository { self.installRepository = installRepository }
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
    
    var runtimeSetupState: RuntimeSetupState { installRepository.setupState }
    func runtimeSetupPublisher() -> AnyPublisher<RuntimeSetupState, Never> { installRepository.setupStatePublisher() }
    func installRuntime() async { await installRepository.install() }
    var lastCompletedReceipt: StateRecoveryResult? { stateRecoveryRepository.lastCompletedReceipt }
    var recoveryState: StoreRecoveryState { stateRecoveryRepository.state }
    func recoveryStatePublisher() -> AnyPublisher<StoreRecoveryState, Never> { stateRecoveryRepository.statePublisher() }
    func inspectStore() async { await stateRecoveryRepository.inspect() }
    func confirmRecovery(_ inspection: StateInspection) { stateRecoveryRepository.requestConfirmation(inspection: inspection) }
    func cancelRecovery() { stateRecoveryRepository.cancelConfirmation() }
    func recoverStore(_ inspection: StateInspection) async {
        guard case .confirming(let current) = stateRecoveryRepository.state, current == inspection else { return }
        await stateRecoveryRepository.recover(inspection: inspection)
        guard let proposal = inspection.recovery, let receipt = stateRecoveryRepository.lastCompletedReceipt,
              receipt.stateRoot == inspection.stateRoot, receipt.engineVersion == inspection.engineVersion,
              receipt.operationID == proposal.operationID, receipt.backupPath == proposal.backupPath else { return }
        taskListRepository.runtimeBecameReady()
    }

    func installStatePublisher() -> AnyPublisher<InstallState, Never> { installRepository.statePublisher() }
    func retryRuntime() async { await installRepository.retry() }

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
