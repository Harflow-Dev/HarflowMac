import Foundation
import HfCommon
import HfUtilities
import SwiftEnvironment

// MARK: - Module

/// Registers `MainWindowFeatureFactory` into `GlobalValues`. Must run after `HfRepository.Module`
/// (decision 13: lowest layer first) — `SidebarViewRepository`/`NewSessionViewRepository` read
/// `TaskListRepository`/`TaskActionRepository`/`ToolEnvironmentRepository` back out of
/// `GlobalValues` via `@GlobalEnvironment`, not as constructor parameters.
public final class Module: HfModule {
    
    override public func initializeModule() {
        super.initializeModule()
        
        GlobalValues.environment(\.mainWindowFeatureFactory, MainWindowFeatureFactoryImpl())
    }
}
