//
//  PbModuleDelegate.swift
//  PbUtilities
//

import Foundation
import Mockable

/// Defines lifecycle callbacks for application modules.
@Mockable
public protocol PbModuleDelegate: AnyObject {
    
    // MARK: - Properties
    
    /// Indicates whether this module has been initialized.
    @MainActor var isInitialized: Bool { get }
    
    // MARK: - Methods
    
    /// This method is called when the app is launched.
    @MainActor func launched()
    
    /// This method is called before all the modules in app is initialized.
    @MainActor func modulesWillInitialize()
    
    /// Put any module initialization code here.
    @MainActor func initializeModule()
    
    /// This method is called after all the modules in app is initialized.
    @MainActor func modulesDidInitialize()
    
    /// This method is called when the app enters background.
    @MainActor func enteringBackground()
    
    /// This method is called when the app enters foreground.
    @MainActor func enteringForeground()
    
    /// This method is called when the app will terminate.
    @MainActor func applicationWillTerminate()
}

// MARK: - PbModule

@MainActor
open class PbModule: PbModuleDelegate {
    
    // MARK: - Public Properties
    
    /// Indicates whether the module has completed initialization.
    public private(set) var isInitialized: Bool = false
    
    // MARK: - Public Methods
    
    /// Creates a module instance.
    public init() {}
    
    /// Performs module initialization.
    open func initializeModule() {
        isInitialized = true
    }
    
    open func launched() {}
    
    open func modulesWillInitialize() {}
    
    open func modulesDidInitialize() {}
    
    open func enteringBackground() {}
    
    open func enteringForeground() {}
    
    open func applicationWillTerminate() {}
}
