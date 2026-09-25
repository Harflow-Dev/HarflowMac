//
//  SettingsCoordinator.swift
//  SettingsFeature
//

import Foundation
import PbCommon
import PbUtilities
import SwiftUI

// MARK: - SettingsNavigationCoordinator

/// Navigation/view-building contract for the Settings scene.
@MainActor
public protocol SettingsNavigationCoordinator: ViewChildCoordinator {
    /// Builds the General settings tab (tool directory + behaviour toggles).
    func buildGeneralSettingsView() -> AnyView
    /// Builds the Harnesses settings tab (MCP client install/remove).
    func buildHarnessesView() -> AnyView
}

// MARK: - SettingsCoordinator

/// The Settings scene's coordinator: builds both tabs and bubbles anything it does not own to its
/// parent. Settings has no destinations of its own — no case in `MonitorDestination` targets it —
/// so `handle(path:)` only ever bubbles.
@MainActor
@Observable
public final class SettingsCoordinator: SettingsNavigationCoordinator {
    
    // MARK: - Public Properties
    
    public let parent: any Coordinator
    public var path: [PathDestination] { [] }
    
    // MARK: - Init
    
    public init(parent: any Coordinator) {
        self.parent = parent
    }
    
    // MARK: - Public Methods
    
    public func handle(path: any PathDestination) {
        parent.handle(path: path)
    }
    
    public func buildGeneralSettingsView() -> AnyView {
        let useCase = GeneralSettingsViewRepository()
        let vm = GeneralSettingsVM(useCase: useCase)
        return GeneralSettingsView(vm).eraseToAnyView()
    }
    
    public func buildHarnessesView() -> AnyView {
        let useCase = HarnessesViewRepository()
        let vm = HarnessesVM(useCase: useCase)
        return HarnessesView(vm).eraseToAnyView()
    }
    
    // MARK: - ViewCoordinator
    
    public func start() -> AnyView {
        SettingsNavigationView(coordinator: self).eraseToAnyView()
    }
}
