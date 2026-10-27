import Foundation
import HfUtilities
import MonitorCore
import SwiftEnvironment

// MARK: - Module

/// Wires every repository's concrete implementation into `GlobalValues`, in dependency order, so an
/// impl constructed later can be handed the already-built earlier instance directly — see the root
/// macOS architecture rule 7 and this package's own AGENTS.md for why construction (not
/// `@GlobalEnvironment` property-wrapper lookups inside each impl) is how that ordering is expressed
/// here.
public final class Module: HfModule {

    override public func initializeModule() {
        super.initializeModule()

        let scheduler = SystemScheduler()
        let visibility = SystemMonitorVisibility()
        let settings = SettingsRepositoryImpl()
        let agentUsage = AgentUsageRepositoryImpl()
        let layout = ManagedRuntimeLayout(home: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
        let baseEnvironment = ProcessInfo.processInfo.environment
        let installer: any ManagedRuntimeInstalling
        do {
            installer = ManagedRuntimeInstaller(layout: layout, specification: try .bundled(), baseEnvironment: baseEnvironment)
        } catch {
            installer = UnavailableManagedRuntimeInstaller(message: error.localizedDescription)
        }
        let runtime = ManagedRuntimeCoordinator(installer: installer)
        let toolEnvironment = ManagedToolEnvironmentRepository(coordinator: runtime, layout: layout, baseEnvironment: baseEnvironment)
        let stateRecovery = StateRecoveryRepositoryImpl(toolEnvironment: toolEnvironment)
        let snapshot = TaskSnapshotRepositoryImpl(toolEnvironment: toolEnvironment)
        let capturedEvents = EventStreamRepositoryImpl(toolEnvironment: toolEnvironment, snapshotRepository: snapshot, scheduler: scheduler)
        let eventStream = RecoveryEventStreamRepository(base: capturedEvents, environment: toolEnvironment, snapshots: snapshot, scheduler: scheduler)
        let finishNotifier = FinishNotifierImpl(settings: settings)
        let taskList = TaskListRepositoryImpl(
            toolEnvironment: toolEnvironment,
            snapshotRepository: snapshot,
            eventStreamRepository: eventStream,
            finishNotifier: finishNotifier,
            scheduler: scheduler,
            visibility: visibility,
            stateRecovery: stateRecovery
        )
        let taskAction = TaskActionRepositoryImpl(toolEnvironment: toolEnvironment, taskListRepository: taskList, snapshotRepository: snapshot)
        let harness = HarnessRepositoryImpl(toolEnvironment: toolEnvironment)
        let install = ManagedInstallRepository(coordinator: runtime, taskListRepository: taskList)
        let takeover = TakeoverServiceImpl(actions: taskAction, toolEnvironment: toolEnvironment, taskList: taskList, snapshots: snapshot)
        let backends = BackendsRepositoryImpl(toolEnvironment: toolEnvironment, installRepository: install, scheduler: scheduler)
        let modelCatalog = ModelCatalogRepositoryImpl(toolEnvironment: toolEnvironment)

        GlobalValues
            .environment(\.scheduling, scheduler)
            .environment(\.monitorVisibility, visibility)
            .environment(\.settingsRepository, settings)
            .environment(\.agentUsageRepository, agentUsage)
            .environment(\.toolEnvironmentRepository, toolEnvironment)
            .environment(\.stateRecoveryRepository, stateRecovery)
            .environment(\.taskSnapshotRepository, snapshot)
            .environment(\.workflowArtifactRepository, WorkflowArtifactRepositoryImpl(toolEnvironment: toolEnvironment))
            .environment(\.taskArtifactRepository, TaskArtifactRepositoryImpl(toolEnvironment: toolEnvironment))
            .environment(\.statisticsRepository, StatisticsRepositoryImpl(toolEnvironment: toolEnvironment, stateRecovery: stateRecovery))
            .environment(\.eventStreamRepository, eventStream)
            .environment(\.finishNotifier, finishNotifier)
            .environment(\.taskListRepository, taskList)
            .environment(\.taskActionRepository, taskAction)
            .environment(\.harnessRepository, harness)
            .environment(\.installRepository, install)
            .environment(\.takeoverService, takeover)
            .environment(\.backendsRepository, backends)
            .environment(\.modelCatalogRepository, modelCatalog)
            .environment(\.workflowRepository, WorkflowRepositoryImpl(toolEnvironment: toolEnvironment, stateRecovery: stateRecovery))
    }
}

// MARK: - UnavailableManagedRuntimeInstaller

private struct UnavailableManagedRuntimeInstaller: ManagedRuntimeInstalling {
    let message: String
    func prepare() async throws -> ManagedRuntimeReady { throw ManagedRuntimeFailure(message) }
}
