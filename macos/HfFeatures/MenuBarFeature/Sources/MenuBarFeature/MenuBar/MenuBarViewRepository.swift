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

/// Concrete `MenuBarUseCase` backed by `TaskListRepository`, `EventStreamRepository` and `InstallRepository`.
@MainActor
final class MenuBarViewRepository: MenuBarUseCase, MenuBarCountAvailabilityUseCase, MenuBarNeedsYouUseCase, @unchecked Sendable {
    
    // MARK: - Private Properties
    
    @GlobalEnvironment(\.taskListRepository) private var taskListRepository
    @GlobalEnvironment(\.eventStreamRepository) private var eventStreamRepository
    @GlobalEnvironment(\.toolEnvironmentRepository) private var toolEnvironmentRepository
    @GlobalEnvironment(\.installRepository) private var installRepository
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
        toolEnvironmentRepository: (any ToolEnvironmentRepository)? = nil,
        installRepository: (any InstallRepository)? = nil
    ) {
        if let taskListRepository { self.taskListRepository = taskListRepository }
        if let eventStreamRepository { self.eventStreamRepository = eventStreamRepository }
        if let toolEnvironmentRepository { self.toolEnvironmentRepository = toolEnvironmentRepository }
        if let installRepository { self.installRepository = installRepository }
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
    var runtimeReady: Bool { installRepository.setupState.isReady }
    func runtimeReadyPublisher() -> AnyPublisher<Bool, Never> { Self.readiness(installRepository.setupStatePublisher()) }

    /// Built in a `nonisolated static` helper because the upstream can emit off the main thread, and a
    /// main-actor closure applied there would trap.
    nonisolated static func readiness(_ states: AnyPublisher<RuntimeSetupState, Never>) -> AnyPublisher<Bool, Never> {
        states.map(\.isReady).removeDuplicates().eraseToAnyPublisher()
    }
    
    func title(_ taskID: String) -> String { taskListRepository.title(taskID) }
    
    func acquireEventLease(_ taskID: String) -> any EventStreamLease { eventStreamRepository.acquire(taskID) }
    func itemsPublisher(_ taskID: String) -> AnyPublisher<[TimelineItem], Never> { eventStreamRepository.itemsPublisher(for: taskID) }
    func current(_ taskID: String) -> TimelineItem? { eventStreamRepository.current(for: taskID) }

    // MARK: Install

    func installStatePublisher() -> AnyPublisher<InstallState, Never> { installRepository.statePublisher() }
    var installState: InstallState { installRepository.state }
    func lastCheckMessagePublisher() -> AnyPublisher<String?, Never> { installRepository.lastCheckMessagePublisher() }
    var lastCheckMessage: String? { installRepository.lastCheckMessage }
    func installAnywayBlockedMessagePublisher() -> AnyPublisher<String?, Never> { installRepository.installAnywayBlockedMessagePublisher() }
    var installAnywayBlockedMessage: String? { installRepository.installAnywayBlockedMessage }
    func installDestination() -> String? { installRepository.destination() }
    func install() async { await installRepository.install() }
    func installUvThenHarflow() async { await installRepository.installUvThenHarflow() }
    func retry() async { await installRepository.retry() }
    func checkAgain() async { await installRepository.checkAgain() }
    @discardableResult
    func installAnyway() async -> Bool { await installRepository.installAnyway() }
    func reset() { installRepository.reset() }

    func installNeed(for error: ToolError) -> InstallNeed? {
        InstallCommands.installNeed(
            for: error,
            ctl: presence(toolEnvironmentRepository.locator.locate("harflow-ctl")),
            setup: presence(toolEnvironmentRepository.locator.locate("harflow-setup"))
        )
    }

    private func presence(_ result: Result<String, ToolError>) -> ToolPresence {
        switch result {
        case .success(let path): .found(path: path)
        case .failure: .notFound
        }
    }
}
