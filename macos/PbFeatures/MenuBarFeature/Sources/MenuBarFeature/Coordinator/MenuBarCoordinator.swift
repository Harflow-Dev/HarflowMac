//
//  MenuBarCoordinator.swift
//  MenuBarFeature
//

import Foundation
import PbCommon
import PbUtilities
import SwiftUI

// MARK: - MenuBarNavigationCoordinator

/// Navigation/view-building contract for the menu bar. Beyond the generic `ViewChildCoordinator`
/// surface, the app target needs two separate view builders sharing one VM — `MenuBarExtra` takes
/// its label and content as two independent view builders. The app target downcasts the factory's
/// `any ViewChildCoordinator` return to this protocol to reach them (see `App.swift`).
@MainActor
public protocol MenuBarNavigationCoordinator: ViewChildCoordinator {
    /// Builds the always-on-screen status item label (icon + running count).
    func buildMenuBarLabelView() -> AnyView
    /// Builds the popover content shown when the status item is clicked.
    func buildMenuBarContentView() -> AnyView
}

// MARK: - MenuBarCoordinator

/// The menu bar's coordinator. Builds one `MenuBarVM`, shared by the label and content views, and
/// itself implements `MenuBarRouting` by forwarding to the parent coordinator.
@MainActor
@Observable
public final class MenuBarCoordinator: MenuBarNavigationCoordinator {
    
    // MARK: - Public Properties
    
    public let parent: any Coordinator
    public var path: [PathDestination] { [] }
    
    // MARK: - Private Properties
    
    private var vm: MenuBarVM?
    
    // MARK: - Init
    
    public init(parent: any Coordinator) {
        self.parent = parent
    }
    
    // MARK: - Public Methods
    
    public func handle(path: any PathDestination) {
        parent.handle(path: path)
    }
    
    public func buildMenuBarLabelView() -> AnyView {
        MenuBarLabelView(sharedVM()).eraseToAnyView()
    }
    
    public func buildMenuBarContentView() -> AnyView {
        MenuBarView(sharedVM()).eraseToAnyView()
    }
    
    // MARK: - ViewCoordinator
    
    public func start() -> AnyView {
        buildMenuBarContentView()
    }
    
    // MARK: - Private Methods
    
    private func sharedVM() -> MenuBarVM {
        if let vm { return vm }
        let useCase = MenuBarViewRepository()
        let newVM = MenuBarVM(useCase: useCase, routing: self)
        vm = newVM
        return newVM
    }
}

// MARK: - MenuBarRouting

extension MenuBarCoordinator: MenuBarRouting {
    
    public func select(_ destination: MonitorDestination) {
        parent.handle(path: destination)
    }
    
    public func openWindow() {
        parent.handle(path: MonitorDestination.openWindow)
    }
    
    public func registerWindowOpener(_ opener: @escaping () -> Void) {
        (parent as? WindowPresenting)?.registerWindowOpener(opener)
    }
}
