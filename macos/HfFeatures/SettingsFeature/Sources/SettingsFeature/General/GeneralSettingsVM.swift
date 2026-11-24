//
//  GeneralSettingsVM.swift
//  SettingsFeature
//

import Combine
import Foundation
import HfCommon
import HfRepository
import HfUtilities
import Mockable
import MonitorCore

// MARK: - GeneralSettingsUseCase

/// Provides the General settings tab's behaviour toggles over `SettingsRepository`; managed-runtime
/// and store-recovery state come through the optional `RuntimeSetupObserving` and `StoreRecoveryUseCase`
/// conformances. No `Routing` protocol: this screen has no navigation.
@Mockable
@MainActor
protocol GeneralSettingsUseCase: Sendable {
    
    var openWindowOnStart: Bool { get }
    var notifyOnFinish: Bool { get }
    var notifyOnNeedsYou: Bool { get }
    var appAppearance: AppAppearance { get }

    func openWindowOnStartPublisher() -> AnyPublisher<Bool, Never>
    func notifyOnFinishPublisher() -> AnyPublisher<Bool, Never>
    func notifyOnNeedsYouPublisher() -> AnyPublisher<Bool, Never>
    func appAppearancePublisher() -> AnyPublisher<AppAppearance, Never>

    func setOpenWindowOnStart(_ value: Bool)
    func setNotifyOnFinish(_ value: Bool)
    func setNotifyOnNeedsYou(_ value: Bool)
    func setAppAppearance(_ value: AppAppearance)
}

// MARK: - GeneralSettingsVM

/// View model for the General settings tab.
@Observable
@MainActor
final class GeneralSettingsVM: GeneralSettingsViewModel {
    
    // MARK: - GeneralSettingsViewModel Properties
    
    private(set) var runtimeSetupState: RuntimeSetupState = .ready
    private(set) var recoveryState: StoreRecoveryState = .idle
    private(set) var lastCompletedReceipt: StateRecoveryResult?
    var recoveryPresentation: StoreRecoveryPresentation {
        StoreRecoveryPresentation(state: recoveryState, receipt: lastCompletedReceipt, runtimeReady: runtimeSetupState.isReady)
    }

    private(set) var appAppearance: AppAppearance
    @ObservationIgnored private let recoveryRouting: (any StoreRecoveryRouting)?
    @ObservationIgnored private let notificationRouting: (any NotificationSettingsRouting)?
    private(set) var notificationRow: NotificationRowPresentation?
    private(set) var openWindowOnStart: Bool
    private(set) var notifyOnFinish: Bool
    private(set) var notifyOnNeedsYou: Bool
    
    // MARK: - Private Properties
    
    @ObservationIgnored private let useCase: any GeneralSettingsUseCase
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var didSubscribe = false
    @ObservationIgnored private var notificationPermission: NotificationAuthorization?
    @ObservationIgnored private var hasReadPermission = false
    @ObservationIgnored private var feedAvailability: NotificationFeedAvailability
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    
    // MARK: - Init
    
    init(
        useCase: any GeneralSettingsUseCase,
        recoveryRouting: (any StoreRecoveryRouting)? = nil,
        notificationRouting: (any NotificationSettingsRouting)? = nil
    ) {
        self.recoveryRouting = recoveryRouting
        self.notificationRouting = notificationRouting
        self.feedAvailability = (useCase as? any NotificationPermissionObserving)?.feedAvailability ?? .unknown
        self.useCase = useCase
        self.runtimeSetupState = (useCase as? any RuntimeSetupObserving)?.runtimeSetupState ?? .ready
        self.recoveryState = (useCase as? any StoreRecoveryUseCase)?.recoveryState ?? .idle
        self.lastCompletedReceipt = (useCase as? any StoreRecoveryUseCase)?.lastCompletedReceipt
        self.openWindowOnStart = useCase.openWindowOnStart
        self.notifyOnFinish = useCase.notifyOnFinish
        self.notifyOnNeedsYou = useCase.notifyOnNeedsYou
        self.appAppearance = useCase.appAppearance
    }
    
    // MARK: - GeneralSettingsViewModel Methods
    
    func didAppear() {
        subscribeIfNeeded()
    }
    
    func didDisappear() {
        permissionTask?.cancel()
        permissionTask = nil
        (useCase as? any StoreRecoveryUseCase)?.cancelRecovery()
        cancellables.removeAll()
        didSubscribe = false
    }
    
    func didToggleOpenWindowOnStart(_ isOn: Bool) {
        useCase.setOpenWindowOnStart(isOn)
    }
    
    func didToggleNotifyOnFinish(_ isOn: Bool) {
        useCase.setNotifyOnFinish(isOn)
    }
    
    func didToggleNotifyOnNeedsYou(_ isOn: Bool) {
        useCase.setNotifyOnNeedsYou(isOn)
    }
    
    func didSelectAppearance(_ appearance: AppAppearance) {
        guard appAppearance != appearance else { return }
        useCase.setAppAppearance(appearance)
        appAppearance = appearance
    }

    // MARK: - Private Methods
    
    private func subscribeIfNeeded() {
        guard !didSubscribe else { return }
        didSubscribe = true
        
        // The sidebar footer shares this setting; catch up with a change made while this tab was away.
        let current = useCase.appAppearance
        if appAppearance != current { appAppearance = current }
        useCase.appAppearancePublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] appearance in
                guard let self, appAppearance != appearance else { return }
                appAppearance = appearance
            }
            .store(in: &cancellables)

        subscribeToSetupAndRecovery()
        subscribeToNotificationPermission()

        useCase.openWindowOnStartPublisher()
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.openWindowOnStart, on: self)
            .store(in: &cancellables)
        
        useCase.notifyOnFinishPublisher()
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.notifyOnFinish, on: self)
            .store(in: &cancellables)
        
        useCase.notifyOnNeedsYouPublisher()
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.notifyOnNeedsYou, on: self)
            .store(in: &cancellables)
    }
    
    func didTapInstallRuntime() {
        guard runtimeSetupState.actionTitle != nil, let setup = useCase as? any RuntimeSetupObserving else { return }
        Task { await setup.installRuntime() }
    }

    func didTapOpenNotificationSettings() { notificationRouting?.openNotificationSettings() }

    func didTapInspectStore() { Task { await (useCase as? any StoreRecoveryUseCase)?.inspectStore() } }
    func didTapRequestRecovery() {
        guard StoreRecoveryPresentation.recoveryActionsAvailable else { return }
        guard case .inspected(let inspection) = recoveryState else { return }
        (useCase as? any StoreRecoveryUseCase)?.confirmRecovery(inspection)
    }

    func didTapCancelRecovery() { (useCase as? any StoreRecoveryUseCase)?.cancelRecovery() }
    func didTapConfirmRecovery() {
        guard StoreRecoveryPresentation.recoveryActionsAvailable else { return }
        guard case .confirming(let inspection) = recoveryState else { return }
        Task { await (useCase as? any StoreRecoveryUseCase)?.recoverStore(inspection) }
    }

    func didTapRevealBackup() {
        guard StoreRecoveryPresentation.recoveryActionsAvailable, let receipt = lastCompletedReceipt else { return }
        recoveryRouting?.revealBackup(receipt)
    }

    private func subscribeToSetupAndRecovery() {
        if let setup = useCase as? any RuntimeSetupObserving {
            setup.runtimeSetupPublisher()
.receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    guard let self, runtimeSetupState != state else { return }
                    runtimeSetupState = state
                }
.store(in: &cancellables)
        }
        if let recovery = useCase as? any StoreRecoveryUseCase {
            recovery.recoveryStatePublisher()
.receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    guard let self else { return }
                    let receipt = recovery.lastCompletedReceipt
                    if lastCompletedReceipt != receipt { lastCompletedReceipt = receipt }
                    if recoveryState != state { recoveryState = state }
                }
.store(in: &cancellables)
        }
    }

    private func subscribeToNotificationPermission() {
        guard let observing = useCase as? any NotificationPermissionObserving else { return }
        refreshPermission(observing)
        observing.feedAvailabilityPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] feed in
                guard let self, feedAvailability != feed else { return }
                feedAvailability = feed
                updateNotificationRow()
            }
            .store(in: &cancellables)
        // The permission is changed in System Settings, so it is read again whenever the app comes back.
        observing.activationPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPermission(observing) }
            .store(in: &cancellables)
    }

    private func refreshPermission(_ observing: any NotificationPermissionObserving) {
        permissionTask?.cancel()
        permissionTask = Task { [weak self] in
            let permission = await observing.notificationPermission()
            guard !Task.isCancelled, let self else { return }
            notificationPermission = permission
            hasReadPermission = true
            updateNotificationRow()
        }
    }

    private func updateNotificationRow() {
        let row = hasReadPermission ? NotificationRowPresentation.row(permission: notificationPermission, feed: feedAvailability) : nil
        if notificationRow != row { notificationRow = row }
    }
}
