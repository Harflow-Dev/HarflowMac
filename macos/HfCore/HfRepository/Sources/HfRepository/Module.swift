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
        let taskPrompt = TaskPromptRepositoryImpl(toolEnvironment: toolEnvironment, recovery: stateRecovery)
        let eventStream = makeEventStream(toolEnvironment: toolEnvironment, snapshot: snapshot, scheduler: scheduler,
                                                taskPrompt: taskPrompt, runtime: runtime)
        let (notificationMode, finishNotifier) = notificationRouting(settings: settings)
        let taskList = TaskListRepositoryImpl(
            toolEnvironment: toolEnvironment,
            snapshotRepository: snapshot,
            eventStreamRepository: eventStream,
            finishNotifier: finishNotifier,
            scheduler: scheduler,
            visibility: visibility, invalidationSource: PollingTaskListInvalidationSource(scheduler: scheduler),
            stateRecovery: stateRecovery
        )
        let taskAction = TaskActionRepositoryImpl(toolEnvironment: toolEnvironment, taskListRepository: taskList, snapshotRepository: snapshot)
        let harness = HarnessRepositoryImpl(toolEnvironment: toolEnvironment)
        let install = ManagedInstallRepository(coordinator: runtime, taskListRepository: taskList)
        let takeover = TakeoverServiceImpl(actions: taskAction, toolEnvironment: toolEnvironment, taskList: taskList, snapshots: snapshot)
        let backends = BackendsRepositoryImpl(toolEnvironment: toolEnvironment, installRepository: install, scheduler: scheduler)
        let workflows = WorkflowRepositoryImpl(toolEnvironment: toolEnvironment, stateRecovery: stateRecovery)

        GlobalValues
            .environment(\.scheduling, scheduler)
            .environment(\.monitorVisibility, visibility)
            .environment(\.settingsRepository, settings)
            .environment(\.agentUsageRepository, agentUsage)
            .environment(\.toolEnvironmentRepository, toolEnvironment)
            .environment(\.stateRecoveryRepository, stateRecovery)
            .environment(\.taskSnapshotRepository, snapshot)
            .environment(\.resourceSlotsRepository, ResourceSlotsRepositoryImpl(tooling: toolEnvironment, scheduler: scheduler))
            .environment(\.eventStreamRepository, eventStream)
            .environment(\.taskPromptRepository, taskPrompt)
            .environment(\.finishNotifier, finishNotifier)
            .environment(\.taskListRepository, taskList)
            .environment(\.taskActionRepository, taskAction)
            .environment(\.harnessRepository, harness)
            .environment(\.installRepository, install)
            .environment(\.takeoverService, takeover)
            .environment(\.backendsRepository, backends)
            .environment(\.modelCatalogRepository, ModelCatalogRepositoryImpl(toolEnvironment: toolEnvironment))
            .environment(\.workflowRepository, workflows)

        registerPublicReaders(toolEnvironment: toolEnvironment, stateRecovery: stateRecovery, taskList: taskList, actions: taskAction, runtime: runtime)
        let shared = NeedsYouDependencies(scheduler: scheduler, visibility: visibility, settings: settings, install: install)
        registerNeedsYou(toolEnvironment: toolEnvironment, workflows: workflows, shared: shared, notificationMode: notificationMode)
    }

    private func makeEventStream(toolEnvironment: any ToolEnvironmentRepository, snapshot: any TaskSnapshotRepository,
                                 scheduler: any Scheduling, taskPrompt: any TaskPromptRepository,
                                 runtime: ManagedRuntimeCoordinator) -> RecoveryEventStreamRepository {
        let repository = EventStreamRepositoryImpl(toolEnvironment: toolEnvironment, snapshotRepository: snapshot, scheduler: scheduler,
                                                  promptRepository: taskPrompt)
        repository.bindRuntimeChanges(runtime.statePublisher())
        let recovery = RecoveryEventStreamRepository(base: repository, environment: toolEnvironment, snapshots: snapshot, scheduler: scheduler)
        recovery.bindRuntimeChanges(runtime.statePublisher())
        return recovery
    }

    private func registerPublicReaders(toolEnvironment: any ToolEnvironmentRepository, stateRecovery: any StateRecoveryRepository,
                                       taskList: any TaskListRepository, actions: any TaskActionRepository, runtime: ManagedRuntimeCoordinator) {
        let pendingLaunch = PendingLaunchRepositoryImpl(tooling: toolEnvironment, taskList: taskList, actions: actions,
                                                        recovery: stateRecovery, now: { .now })
        pendingLaunch.bindRuntimeChanges(runtime.statePublisher())
        GlobalValues
            .environment(\.pendingLaunchRepository, pendingLaunch)
            .environment(\.workflowArtifactRepository, WorkflowArtifactRepositoryImpl(toolEnvironment: toolEnvironment))
            .environment(\.taskArtifactRepository, TaskArtifactRepositoryImpl(toolEnvironment: toolEnvironment))
            .environment(\.taskChangesRepository, TaskChangesRepositoryImpl(toolEnvironment: toolEnvironment, recovery: stateRecovery, now: { .now }))
            .environment(\.qualificationRepository, QualificationRepositoryImpl(tooling: toolEnvironment, recovery: stateRecovery))
            .environment(\.taskContinuationRepository, TaskContinuationRepositoryImpl(tooling: toolEnvironment, taskList: taskList,
                                                                                       actions: actions, now: { .now }))
            .environment(\.statisticsRepository, StatisticsRepositoryImpl(toolEnvironment: toolEnvironment, stateRecovery: stateRecovery))
    }

    private func notificationRouting(settings: any SettingsRepository) -> (NotificationDeliveryMode, FinishNotifierImpl) {
        let mode = NotificationDeliveryMode()
        return (mode, FinishNotifierImpl(settings: settings, isEnabled: { mode.allowsLegacy }))
    }

    /// The seams Needs you shares with the other repositories.
    private struct NeedsYouDependencies {
        let scheduler: any Scheduling
        let visibility: any MonitorVisibility
        let settings: any SettingsRepository
        let install: any InstallRepository
    }

    private func registerNeedsYou(
        toolEnvironment: any ToolEnvironmentRepository, workflows: any WorkflowRepository, shared: NeedsYouDependencies,
        notificationMode: NotificationDeliveryMode
    ) {
        let needsYou = NeedsYouRepositoryImpl(
            toolEnvironment: toolEnvironment, workflows: workflows, scheduler: shared.scheduler, visibility: shared.visibility,
            install: shared.install
        )
        let legacy = NeedsYouNotifierImpl(repository: needsYou, settings: shared.settings, scheduler: shared.scheduler,
                                          isEnabled: { notificationMode.allowsLegacy })
        let notifier = InteractionEventNotifier(tooling: toolEnvironment, install: shared.install, settings: shared.settings,
                                               scheduler: shared.scheduler, center: SystemNotificationCenter(), legacy: legacy, mode: notificationMode)
        GlobalValues
            .environment(\.needsYouRepository, needsYou)
            .environment(\.needsYouNotifier, notifier)
    }
}

// MARK: - UnavailableManagedRuntimeInstaller

private struct UnavailableManagedRuntimeInstaller: ManagedRuntimeInstalling {
    let message: String
    func prepare() async throws -> ManagedRuntimeReady { throw ManagedRuntimeFailure(message) }
}
