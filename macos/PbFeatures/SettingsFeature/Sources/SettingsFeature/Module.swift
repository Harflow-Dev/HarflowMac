import Foundation
import PbCommon
import PbUtilities
import SwiftEnvironment

// MARK: - Module

/// Registers `SettingsFeatureFactory` into `GlobalValues`. Must run after `PbRepository.Module`
/// (decision 13: lowest layer first) — the feature's `ViewRepository`s read `SettingsRepository`,
/// `ToolEnvironmentRepository`, `TaskListRepository` and `HarnessRepository` back out of
/// `GlobalValues` via `@GlobalEnvironment`, not as constructor parameters.
public final class Module: PbModule {
    
    override public func initializeModule() {
        super.initializeModule()
        
        GlobalValues.environment(\.settingsFeatureFactory, SettingsFeatureFactoryImpl())
    }
}
