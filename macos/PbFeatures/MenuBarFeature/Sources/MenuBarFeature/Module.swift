import Foundation
import PbCommon
import PbUtilities
import SwiftEnvironment

// MARK: - Module

/// Registers `MenuBarFeatureFactory` into `GlobalValues`. Must run after `PbRepository.Module`
/// (decision 13: lowest layer first) — `MenuBarViewRepository` reads `TaskListRepository`,
/// `SettingsRepository` and `EventStreamRepository` back out of `GlobalValues` via
/// `@GlobalEnvironment`, not as constructor parameters.
public final class Module: PbModule {
    
    override public func initializeModule() {
        super.initializeModule()
        
        GlobalValues.environment(\.menuBarFeatureFactory, MenuBarFeatureFactoryImpl())
    }
}
