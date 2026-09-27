import Foundation
import PbUtilities
import SwiftEnvironment

// MARK: - Module

/// Wires every repository's concrete implementation into `GlobalValues`, in dependency order, so an
/// impl constructed later can be handed the already-built earlier instance directly — see the root
/// AGENTS.md's rule 7 and this package's own AGENTS.md for why construction (not
/// `@GlobalEnvironment` property-wrapper lookups inside each impl) is how that ordering is expressed
/// here.
public final class Module: PbModule {

    override public func initializeModule() {
        super.initializeModule()

        let scheduler = SystemScheduler()
        let settings = SettingsRepositoryImpl()
        let toolEnvironment = ToolEnvironmentRepositoryImpl(settings: settings)
        let snapshot = TaskSnapshotRepositoryImpl(toolEnvironment: toolEnvironment)
        let eventStream = EventStreamRepositoryImpl(toolEnvironment: toolEnvironment, snapshotRepository: snapshot)
        let finishNotifier = FinishNotifierImpl(settings: settings)
        let taskList = TaskListRepositoryImpl(
            toolEnvironment: toolEnvironment,
            snapshotRepository: snapshot,
            eventStreamRepository: eventStream,
            finishNotifier: finishNotifier,
            scheduler: scheduler
        )
        let taskAction = TaskActionRepositoryImpl(toolEnvironment: toolEnvironment, taskListRepository: taskList, snapshotRepository: snapshot)
        let harness = HarnessRepositoryImpl(toolEnvironment: toolEnvironment)
        let install = InstallRepositoryImpl(toolEnvironment: toolEnvironment, taskListRepository: taskList, settings: settings)
        let takeover = TakeoverServiceImpl(actions: taskAction, toolEnvironment: toolEnvironment, taskList: taskList, snapshots: snapshot)

        GlobalValues
            .environment(\.scheduling, scheduler)
            .environment(\.settingsRepository, settings)
            .environment(\.toolEnvironmentRepository, toolEnvironment)
            .environment(\.taskSnapshotRepository, snapshot)
            .environment(\.eventStreamRepository, eventStream)
            .environment(\.finishNotifier, finishNotifier)
            .environment(\.taskListRepository, taskList)
            .environment(\.taskActionRepository, taskAction)
            .environment(\.harnessRepository, harness)
            .environment(\.installRepository, install)
            .environment(\.takeoverService, takeover)
    }
}
