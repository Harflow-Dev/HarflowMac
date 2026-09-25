//
//  GeneralSettingsVM.swift
//  SettingsFeature
//

import Combine
import Foundation
import Mockable
import MonitorCore
import PbCommon
import PbUtilities

// MARK: - GeneralSettingsUseCase

/// Provides the General settings tab's state and operations over `SettingsRepository` and
/// `ToolEnvironmentRepository`. No `Routing` protocol: this screen has no navigation.
@Mockable
@MainActor
protocol GeneralSettingsUseCase: Sendable {
    
    var toolDirectory: String { get }
    var openWindowOnStart: Bool { get }
    var notifyOnFinish: Bool { get }
    var searchDirectories: [String] { get }
    
    func resolve(_ tool: String) -> ToolResolution
    
    func toolDirectoryPublisher() -> AnyPublisher<String, Never>
    func openWindowOnStartPublisher() -> AnyPublisher<Bool, Never>
    func notifyOnFinishPublisher() -> AnyPublisher<Bool, Never>
    
    /// The original re-evaluated the locator's search directories and resolved paths on every
    /// `AppModel` publish, so Settings updated once discovery (finding the `uv` tool directory)
    /// finished. Discovery always completes before the first listing, so these three re-trigger the
    /// same refresh here.
    func tasksPublisher() -> AnyPublisher<[TaskInfo], Never>
    func hasListedPublisher() -> AnyPublisher<Bool, Never>
    func listErrorPublisher() -> AnyPublisher<ToolError?, Never>
    
    /// Sets the tool directory override and triggers the "changing toolDirectory refreshes the
    /// list, nothing else reruns" behaviour (decision 11/F4-05).
    func setToolDirectory(_ value: String)
    func setOpenWindowOnStart(_ value: Bool)
    func setNotifyOnFinish(_ value: Bool)
}

// MARK: - GeneralSettingsVM

/// View model for the General settings tab.
@Observable
@MainActor
final class GeneralSettingsVM: GeneralSettingsViewModel {
    
    // MARK: - GeneralSettingsViewModel Properties
    
    private(set) var directoryField: String = ""
    private(set) var searchedDirectoriesText: String = ""
    private(set) var ctlResolution: ToolResolution = .notFound
    private(set) var setupResolution: ToolResolution = .notFound
    private(set) var openWindowOnStart: Bool
    private(set) var notifyOnFinish: Bool
    
    // MARK: - Private Properties
    
    @ObservationIgnored private let useCase: any GeneralSettingsUseCase
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var didSubscribe = false
    
    // MARK: - Init
    
    init(useCase: any GeneralSettingsUseCase) {
        self.useCase = useCase
        self.openWindowOnStart = useCase.openWindowOnStart
        self.notifyOnFinish = useCase.notifyOnFinish
        refreshResolutions()
    }
    
    // MARK: - GeneralSettingsViewModel Methods
    
    func didAppear() {
        directoryField = useCase.toolDirectory
        subscribeIfNeeded()
    }
    
    func didDisappear() {
        cancellables.removeAll()
        didSubscribe = false
    }
    
    func didChangeDirectoryField(_ text: String) {
        directoryField = text
    }
    
    /// Trims whitespace before storing — the field itself keeps whatever the user typed, exactly
    /// as the old `SettingsView.apply()` only trimmed the value handed to `AppModel.toolDirectory`.
    func didTapApply() {
        useCase.setToolDirectory(directoryField.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    
    func didTapSearchAgain() {
        directoryField = ""
        useCase.setToolDirectory("")
    }
    
    func didToggleOpenWindowOnStart(_ isOn: Bool) {
        useCase.setOpenWindowOnStart(isOn)
    }
    
    func didToggleNotifyOnFinish(_ isOn: Bool) {
        useCase.setNotifyOnFinish(isOn)
    }
    
    // MARK: - Private Methods
    
    private func subscribeIfNeeded() {
        guard !didSubscribe else { return }
        didSubscribe = true
        
        useCase.toolDirectoryPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshResolutions() }
            .store(in: &cancellables)
        
        // Discovery (finding the `uv` tool directory) always completes before the first listing, so
        // any of these settling is also a signal to re-resolve (item 7).
        useCase.tasksPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshResolutions() }
            .store(in: &cancellables)
        
        useCase.hasListedPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshResolutions() }
            .store(in: &cancellables)
        
        useCase.listErrorPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshResolutions() }
            .store(in: &cancellables)
        
        useCase.openWindowOnStartPublisher()
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.openWindowOnStart, on: self)
            .store(in: &cancellables)
        
        useCase.notifyOnFinishPublisher()
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.notifyOnFinish, on: self)
            .store(in: &cancellables)
    }
    
    private func refreshResolutions() {
        searchedDirectoriesText = useCase.searchDirectories.joined(separator: ", ")
        ctlResolution = useCase.resolve("polybridge-ctl")
        setupResolution = useCase.resolve("polybridge-setup")
    }
}
