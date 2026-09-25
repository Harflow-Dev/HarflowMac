//
//  ApplicationModules.swift
//  PbUtilities
//

import Foundation

/// Coordinates lifecycle events across multiple `PbModuleDelegate` instances.
@MainActor
public final class ApplicationModules {
    
    // MARK: - Internal Properties
    
    let modules: [any PbModuleDelegate]
    
    // MARK: - Public Methods
    
    /// Creates a module coordinator with a prebuilt module collection.
    ///
    /// - Parameter modules: Modules to manage.
    public init(modules: [any PbModuleDelegate]) {
        self.modules = modules
    }
    
    /// Creates a module coordinator from variadic modules.
    ///
    /// - Parameter modules: Modules to manage.
    public init(_ modules: any PbModuleDelegate...) {
        self.modules = modules
    }
    
    /// Runs full initialization for all modules: `modulesWillInitialize()` on every module, then
    /// `initializeModule()` on every module, then `modulesDidInitialize()` on every module — so an
    /// initializer can resolve values registered by an earlier module in the list, and a value
    /// registered only during `initializeModule()` is still visible by the time
    /// `modulesDidInitialize()` runs.
    public func initialize() {
        initialize(modules)
    }
    
    /// Notifies modules that the app has launched.
    public func launched() {
        modules.forEach { $0.launched() }
    }
    
    /// Notifies modules that the app is entering background.
    public func enteringBackground() {
        modules.forEach { $0.enteringBackground() }
    }
    
    /// Notifies modules that the app is entering foreground.
    public func enteringForeground() {
        modules.forEach { $0.enteringForeground() }
    }
    
    /// Initializes only modules that have not been initialized yet.
    public func reinitializeIfNeeded() {
        initialize(modules.filter { !$0.isInitialized })
    }
    
    /// Notifies modules that the app is about to terminate.
    public func applicationWillTerminate() {
        modules.forEach { $0.applicationWillTerminate() }
    }
    
    // MARK: - Private Methods
    
    private func initialize(_ modules: [any PbModuleDelegate]) {
        modules.forEach { $0.modulesWillInitialize() }
        modules.forEach { $0.initializeModule() }
        modules.forEach { $0.modulesDidInitialize() }
    }
}
