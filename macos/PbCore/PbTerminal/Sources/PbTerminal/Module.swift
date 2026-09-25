import Foundation
import PbRepository
import PbUtilities
import SwiftEnvironment

// MARK: - Module

/// Wires the session registry and `TakeoverService` into `GlobalValues`. Must run **after**
/// `PbRepository.Module` (decision 13: lowest layer first) — it reads `TaskActionRepository`,
/// `ToolEnvironmentRepository`, `TaskListRepository` and `TaskSnapshotRepository` back out of
/// `GlobalValues` rather than taking them as constructor parameters, because (unlike
/// `PbRepository.Module`, which owns its whole vertical in one place) `PbTerminal`'s `Module` is a
/// separate package with no reference to the concrete instances `PbRepository.Module` built.
public final class Module: PbModule {

    override public func initializeModule() {
        super.initializeModule()

        let registry = TerminalSessionRegistryImpl()
        let takeoverService = TakeoverServiceImpl(
            actions: GlobalValues.taskActionRepository,
            toolEnvironment: GlobalValues.toolEnvironmentRepository,
            taskList: GlobalValues.taskListRepository,
            snapshots: GlobalValues.taskSnapshotRepository,
            registry: registry
        )

        GlobalValues
            .environment(\.terminalSessionRegistry, registry)
            .environment(\.takeoverService, takeoverService)
    }
}
