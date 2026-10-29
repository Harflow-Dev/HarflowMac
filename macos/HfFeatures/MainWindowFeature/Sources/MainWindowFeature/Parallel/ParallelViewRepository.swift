//
//  ParallelViewRepository.swift
//  MainWindowFeature
//

import Combine
import Foundation
import HfRepository
import MonitorCore
import SwiftEnvironment

// MARK: - ParallelViewRepository

/// Concrete `ParallelUseCase` backed by `TaskListRepository`, `TaskSnapshotRepository`,
/// `TaskActionRepository`, `EventStreamRepository` and `TakeoverService`.
@MainActor
final class ParallelViewRepository: ParallelUseCase, ParallelActivityReadiness, @unchecked Sendable {

    // MARK: - Private Properties

    @GlobalEnvironment(\.taskListRepository) private var taskListRepository
    @GlobalEnvironment(\.taskSnapshotRepository) private var taskSnapshotRepository
    @GlobalEnvironment(\.taskActionRepository) private var taskActionRepository
    @GlobalEnvironment(\.eventStreamRepository) private var eventStreamRepository
    @GlobalEnvironment(\.toolEnvironmentRepository) private var toolEnvironmentRepository
    @GlobalEnvironment(\.takeoverService) private var takeoverService

    // MARK: - Init

    init(
        taskListRepository: (any TaskListRepository)? = nil,
        taskSnapshotRepository: (any TaskSnapshotRepository)? = nil,
        taskActionRepository: (any TaskActionRepository)? = nil,
        eventStreamRepository: (any EventStreamRepository)? = nil,
        takeoverService: (any TakeoverService)? = nil,
        toolEnvironmentRepository: (any ToolEnvironmentRepository)? = nil
    ) {
        if let taskListRepository { self.taskListRepository = taskListRepository }
        if let taskSnapshotRepository { self.taskSnapshotRepository = taskSnapshotRepository }
        if let taskActionRepository { self.taskActionRepository = taskActionRepository }
        if let eventStreamRepository { self.eventStreamRepository = eventStreamRepository }
        if let takeoverService { self.takeoverService = takeoverService }
        if let toolEnvironmentRepository { self.toolEnvironmentRepository = toolEnvironmentRepository }
    }

    // MARK: - ParallelUseCase Methods

    func activityReadyPublisher() -> AnyPublisher<Bool, Never> {
        taskListRepository.hasListedPublisher()
.combineLatest(taskListRepository.historyStatePublisher())
            .receive(on: DispatchQueue.main)
            .map { listed, state in listed && state.catalogState.isReady && !state.bootstrapPending && !state.authorityIncomplete }
            .removeDuplicates()
.eraseToAnyPublisher()
    }

    func tasksPublisher() -> AnyPublisher<[TaskInfo], Never> { taskListRepository.tasksPublisher() }
    func snapshotsPublisher() -> AnyPublisher<[String: TaskInfo], Never> { taskSnapshotRepository.snapshotsPublisher() }
    func busyPublisher() -> AnyPublisher<Set<String>, Never> { taskActionRepository.busyPublisher() }
    func outcomesPublisher() -> AnyPublisher<[String: String], Never> { taskActionRepository.outcomesPublisher() }
    func titlesPublisher() -> AnyPublisher<[String: String], Never> { taskListRepository.titlesPublisher() }

    func task(_ id: String) -> TaskInfo? { taskListRepository.task(id) }
    func title(_ taskID: String) -> String { taskListRepository.title(taskID) }

    func acquireEventLease(_ taskID: String) -> any EventStreamLease { eventStreamRepository.acquire(taskID) }
    func events(for taskID: String) -> [TaskEvent] { eventStreamRepository.events(for: taskID) }
    func items(for taskID: String) -> [TimelineItem] { eventStreamRepository.items(for: taskID) }
    func itemsPublisher(for taskID: String) -> AnyPublisher<[TimelineItem], Never> { eventStreamRepository.itemsPublisher(for: taskID) }
    func prompt(for taskID: String) -> String? { eventStreamRepository.prompt(for: taskID) }
    func eventHistory(for taskID: String) -> EventHistoryState { eventStreamRepository.history(for: taskID) }
    func eventHistoryPublisher(for taskID: String) -> AnyPublisher<EventHistoryState, Never> {
        eventStreamRepository.historyPublisher(for: taskID)
    }

    func conversationHistory(sessionID: String, cursor: String?) async throws -> TaskHistoryPage? {
        try await taskListRepository.conversationPage(sessionID: sessionID, cursor: cursor, limit: 100)
    }

    @discardableResult func loadMoreEvents(_ taskID: String) -> Bool { eventStreamRepository.loadMore(taskID) }
    func eventsAvailability(for taskID: String) -> EventAvailability { eventStreamRepository.eventsAvailability(for: taskID) }
    func eventsAvailabilityPublisher(for taskID: String) -> AnyPublisher<EventAvailability, Never> {
        eventStreamRepository.eventsAvailabilityPublisher(for: taskID)
    }

    func runningInSubtrees(of ids: [String]) -> [String] { taskListRepository.runningInSubtrees(of: ids) }
    func cancelAll(_ ids: [String]) async { await taskActionRepository.cancelAll(ids) }
    func setOutcome(_ id: String, _ text: String?) { taskActionRepository.setOutcome(id, text) }

    func sendMessage(_ id: String, text: String, now: Bool) async throws -> [String: JSONValue] {
        try await performMessage(id) { client in
            if now { return try await client.sendNow(id, text: text).get() }
            return try await client.send(id, text: text).get()
        }
    }

    func cancelMessage(_ id: String, messageID: String) async throws {
        try await performMessage(id) { client in
            _ = try await client.cancelMessage(id, messageID: messageID).get()
            return ["status": .string("cancelled"), "reason": .string("Queued message cancelled.")]
        }
    }

    @discardableResult
    private func performMessage(_ id: String, action: (CtlClient) async throws -> [String: JSONValue]) async throws -> [String: JSONValue] {
        guard taskActionRepository.tryBeginBusy(id) else {
            throw ToolError.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "A task action is already in progress.")
        }
        defer { taskActionRepository.endBusy(id) }
        do {
            let client = try toolEnvironmentRepository.ctl().get()
            let response = try await action(client)
            taskActionRepository.setOutcome(id, WorkMessageOutcome.describe(response))
            await taskSnapshotRepository.refresh(id)
            await taskListRepository.refresh()
            return response
        } catch {
            taskActionRepository.setOutcome(id, (error as? ToolError)?.message ?? error.localizedDescription)
            await taskSnapshotRepository.refresh(id)
            throw error
        }
    }

    func beginTakeover(taskID: String) { takeoverService.beginTakeover(taskID: taskID) }
}
