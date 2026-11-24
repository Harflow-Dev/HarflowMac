//
//  MenuBarViewRepository.swift
//  MenuBarFeature
//

import Combine
import Foundation
import HfRepository
import MonitorCore
import SwiftEnvironment

// MARK: - MenuBarViewRepository

/// Concrete `MenuBarUseCase` backed by `TaskListRepository`, `EventStreamRepository`, `InstallRepository` and `StateRecoveryRepository`.
@MainActor
final class MenuBarViewRepository: MenuBarUseCase, MenuBarCountAvailabilityUseCase, MenuBarNeedsYouUseCase, @unchecked Sendable {
    
    // MARK: - Private Properties
    
    @GlobalEnvironment(\.taskListRepository) private var taskListRepository
    @GlobalEnvironment(\.eventStreamRepository) private var eventStreamRepository
    @GlobalEnvironment(\.installRepository) private var installRepository
    @GlobalEnvironment(\.stateRecoveryRepository) private var stateRecoveryRepository
    @GlobalEnvironment(\.approvalResponseOwner) private var approvalResponseOwner
    @GlobalEnvironment(\.needsYouRepository) private var needsYouRepository

    func respondToApproval(_ item: NeedsYouItem, decision: String) async -> NeedsYouAnswerOutcome { await needsYouRepository.respond(item, decision: decision) }
    func isApprovalContextCurrent(_ item: NeedsYouItem) -> Bool {
        item.approvalContext.map { approvalResponseOwner.isCurrent($0) } == true
    }

    func retainedApprovalResult(_ item: NeedsYouItem) -> ApprovalResponseOutcome? {
        guard let request = item.approval, let context = item.approvalContext, approvalResponseOwner.isCurrent(context) else { return nil }
        return approvalResponseOwner.retained(request, context: context)
    }

    func canReviewApprovalAgain(_ item: NeedsYouItem) async -> Bool {
        guard let request = item.approval, let context = item.approvalContext else { return false }
        return await approvalResponseOwner.canReviewAgain(request, context: context)
    }

    func refreshNeedsYou() { needsYouRepository.refresh() }
    var needsYouSnapshot: NeedsYouSnapshot { needsYouRepository.snapshot }
    func needsYouSnapshotPublisher() -> AnyPublisher<NeedsYouSnapshot, Never> { needsYouRepository.snapshotPublisher() }

    // MARK: - Init

    init(
        taskListRepository: (any TaskListRepository)? = nil,
        eventStreamRepository: (any EventStreamRepository)? = nil,
        installRepository: (any InstallRepository)? = nil,
        stateRecoveryRepository: (any StateRecoveryRepository)? = nil
    ) {
        if let taskListRepository { self.taskListRepository = taskListRepository }
        if let eventStreamRepository { self.eventStreamRepository = eventStreamRepository }
        if let installRepository { self.installRepository = installRepository }
        if let stateRecoveryRepository { self.stateRecoveryRepository = stateRecoveryRepository }
    }
    
    // MARK: - MenuBarUseCase Methods
    
    func tasksPublisher() -> AnyPublisher<[TaskInfo], Never> { taskListRepository.tasksPublisher() }
    func listErrorPublisher() -> AnyPublisher<ToolError?, Never> { taskListRepository.listErrorPublisher() }
    func hasListedPublisher() -> AnyPublisher<Bool, Never> { taskListRepository.hasListedPublisher() }
    func titlesPublisher() -> AnyPublisher<[String: String], Never> { taskListRepository.titlesPublisher() }
    func countsPublisher() -> AnyPublisher<TaskListCounts, Never> { taskListRepository.countsPublisher() }
    
    var connectionLine: String { taskListRepository.connectionLine }
    var countsComplete: Bool { taskListRepository.historyState.countsComplete }
    var runningCount: Int { taskListRepository.runningCount }
    var runtimeSetupState: RuntimeSetupState { installRepository.setupState }
    func runtimeSetupStatePublisher() -> AnyPublisher<RuntimeSetupState, Never> {
        installRepository.setupStatePublisher().removeDuplicates().eraseToAnyPublisher()
    }

    var workAvailable: Bool {
        Self.workAvailability(setup: installRepository.setupState, listError: taskListRepository.listError, store: stateRecoveryRepository.state)
    }

    func workAvailablePublisher() -> AnyPublisher<Bool, Never> {
        Self.workAvailability(
            setup: installRepository.setupStatePublisher(),
            listErrors: taskListRepository.listErrorPublisher(),
            stores: stateRecoveryRepository.statePublisher()
        )
    }

    func refreshWork() async { await taskListRepository.refresh() }

    /// Work can start while the runtime is ready and no contract, capability or store gate refuses it: the same
    /// classification the main window uses to block creation.
    nonisolated static func workAvailability(setup: RuntimeSetupState, listError: ToolError?, store: StoreRecoveryState) -> Bool {
        setup.isReady && MainWindowGate.classify(runtimeReady: true, listError: listError, storeState: store) == nil
    }

    /// Built in a `nonisolated static` helper because the upstreams can emit off the main thread, and a main-actor
    /// closure applied there would trap.
    nonisolated static func workAvailability(
        setup: AnyPublisher<RuntimeSetupState, Never>,
        listErrors: AnyPublisher<ToolError?, Never>,
        stores: AnyPublisher<StoreRecoveryState, Never>
    ) -> AnyPublisher<Bool, Never> {
        Publishers.CombineLatest3(setup, listErrors, stores)
            .map { workAvailability(setup: $0, listError: $1, store: $2) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func title(_ taskID: String) -> String { taskListRepository.title(taskID) }
    
    func acquireEventLease(_ taskID: String) -> any EventStreamLease { eventStreamRepository.acquire(taskID) }
    func itemsPublisher(_ taskID: String) -> AnyPublisher<[TimelineItem], Never> { eventStreamRepository.itemsPublisher(for: taskID) }
    func current(_ taskID: String) -> TimelineItem? { eventStreamRepository.current(for: taskID) }
}
