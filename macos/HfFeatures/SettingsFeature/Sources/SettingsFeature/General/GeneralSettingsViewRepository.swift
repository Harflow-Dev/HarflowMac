//
//  GeneralSettingsViewRepository.swift
//  SettingsFeature
//

import AppKit
import Combine
import Foundation
import HfRepository
import MonitorCore
import SwiftEnvironment

// MARK: - GeneralSettingsViewRepository

/// Concrete `GeneralSettingsUseCase` backed by `SettingsRepository`, the install, store-recovery and task-list repositories.
@MainActor
final class GeneralSettingsViewRepository: GeneralSettingsUseCase, RuntimeSetupObserving, StoreRecoveryUseCase,
    NotificationPermissionObserving, @unchecked Sendable {
    
    // MARK: - Private Properties
    
    @GlobalEnvironment(\.stateRecoveryRepository) private var stateRecoveryRepository
    @GlobalEnvironment(\.installRepository) private var installRepository
    @GlobalEnvironment(\.settingsRepository) private var settingsRepository
    @GlobalEnvironment(\.taskListRepository) private var taskListRepository
    @GlobalEnvironment(\.needsYouNotifier) private var needsYouNotifier

    // MARK: - Init

    init(
        settingsRepository: (any SettingsRepository)? = nil,
        taskListRepository: (any TaskListRepository)? = nil,
        installRepository: (any InstallRepository)? = nil,
        stateRecoveryRepository: (any StateRecoveryRepository)? = nil,
        needsYouNotifier: (any NeedsYouNotifier)? = nil
    ) {
        if let stateRecoveryRepository { self.stateRecoveryRepository = stateRecoveryRepository }
        if let installRepository { self.installRepository = installRepository }
        if let settingsRepository { self.settingsRepository = settingsRepository }
        if let taskListRepository { self.taskListRepository = taskListRepository }
        if let needsYouNotifier { self.needsYouNotifier = needsYouNotifier }
    }
    
    // MARK: - GeneralSettingsUseCase Properties
    
    var openWindowOnStart: Bool { settingsRepository.openWindowOnStart }
    var notifyOnFinish: Bool { settingsRepository.notifyOnFinish }
    var notifyOnNeedsYou: Bool { settingsRepository.notifyOnNeedsYou }
    var appAppearance: AppAppearance { settingsRepository.appAppearance }
    
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

    func notificationPermission() async -> NotificationAuthorization? { await needsYouNotifier.permission() }
    var feedAvailability: NotificationFeedAvailability { needsYouNotifier.feedAvailability }
    func feedAvailabilityPublisher() -> AnyPublisher<NotificationFeedAvailability, Never> { needsYouNotifier.feedAvailabilityPublisher() }
    func activationPublisher() -> AnyPublisher<Void, Never> {
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).map { _ in }.eraseToAnyPublisher()
    }

    func openWindowOnStartPublisher() -> AnyPublisher<Bool, Never> { settingsRepository.openWindowOnStartPublisher() }
    func notifyOnFinishPublisher() -> AnyPublisher<Bool, Never> { settingsRepository.notifyOnFinishPublisher() }
    func notifyOnNeedsYouPublisher() -> AnyPublisher<Bool, Never> { settingsRepository.notifyOnNeedsYouPublisher() }
    func appAppearancePublisher() -> AnyPublisher<AppAppearance, Never> { settingsRepository.appAppearancePublisher() }
    
    func setOpenWindowOnStart(_ value: Bool) { settingsRepository.setOpenWindowOnStart(value) }
    func setNotifyOnFinish(_ value: Bool) { settingsRepository.setNotifyOnFinish(value) }
    func setNotifyOnNeedsYou(_ value: Bool) { settingsRepository.setNotifyOnNeedsYou(value) }
    func setAppAppearance(_ value: AppAppearance) { settingsRepository.setAppAppearance(value) }
}
