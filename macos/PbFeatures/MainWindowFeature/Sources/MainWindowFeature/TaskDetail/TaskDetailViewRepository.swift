//
//  TaskDetailViewRepository.swift
//  MainWindowFeature
//

import Combine
import Foundation
import MonitorCore
import PbRepository
import SwiftEnvironment

// MARK: - TaskDetailViewRepository

/// Concrete `TaskDetailUseCase` backed by `TaskListRepository`, `TaskSnapshotRepository`,
/// `TaskActionRepository`, `EventStreamRepository`, `TakeoverService` and `ToolEnvironmentRepository`.
@MainActor
final class TaskDetailViewRepository: TaskDetailUseCase, @unchecked Sendable {

    // MARK: - Private Properties

    @GlobalEnvironment(\.taskListRepository) private var taskListRepository
    @GlobalEnvironment(\.taskSnapshotRepository) private var taskSnapshotRepository
    @GlobalEnvironment(\.taskActionRepository) private var taskActionRepository
    @GlobalEnvironment(\.eventStreamRepository) private var eventStreamRepository
    @GlobalEnvironment(\.takeoverService) private var takeoverService
    @GlobalEnvironment(\.toolEnvironmentRepository) private var toolEnvironmentRepository

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
    
    // MARK: - TaskDetailUseCase Methods
    
    func tasksPublisher() -> AnyPublisher<[TaskInfo], Never> { taskListRepository.tasksPublisher() }
    func hasListedPublisher() -> AnyPublisher<Bool, Never> { taskListRepository.hasListedPublisher() }
    func titlesPublisher() -> AnyPublisher<[String: String], Never> { taskListRepository.titlesPublisher() }
    func detail(_ id: String) -> TaskInfo? { taskListRepository.detail(id) }
    func task(_ id: String) -> TaskInfo? { taskListRepository.task(id) }
    func title(_ id: String) -> String { taskListRepository.title(id) }
    func ancestors(of id: String) -> [TaskInfo] { Lineage.ancestors(of: id, in: taskListRepository.tasks) }
    func children(of id: String) -> [TaskInfo] { Lineage.children(of: id, in: taskListRepository.tasks) }
    /// The current parent's other children (F4-38's lineage list) — every child of the nearest
    /// ancestor, current task included, or none for a root task.
    func siblings(of id: String) -> [TaskInfo] {
        let tasks = taskListRepository.tasks
        guard let parent = Lineage.ancestors(of: id, in: tasks).last else { return [] }
        return Lineage.children(of: parent.taskID, in: tasks)
    }

    func conversationMembers(of id: String) -> [TaskInfo] {
        Lineage.conversation(containing: id, in: taskListRepository.tasks)?.members ?? []
    }

    func cancelScope(of id: String) -> Set<String> { Lineage.cancelScope(of: id, in: taskListRepository.tasks) }
    func oldestSurvivor(among candidates: Set<String>) -> String? { Lineage.oldestSurvivor(among: candidates, in: taskListRepository.tasks) }

    func snapshot(_ id: String) -> TaskInfo? { taskSnapshotRepository.snapshot(id) }
    func snapshotsPublisher() -> AnyPublisher<[String: TaskInfo], Never> { taskSnapshotRepository.snapshotsPublisher() }
    func refreshSnapshot(_ id: String) async { await taskSnapshotRepository.refresh(id) }
    
    func busyPublisher() -> AnyPublisher<Set<String>, Never> { taskActionRepository.busyPublisher() }
    func outcomesPublisher() -> AnyPublisher<[String: String], Never> { taskActionRepository.outcomesPublisher() }
    
    @discardableResult func cancel(_ id: String) async throws -> Bool { try await taskActionRepository.cancel(id) }
    @discardableResult func send(_ id: String, text: String) async throws -> Bool { try await taskActionRepository.send(id, text: text) }
    @discardableResult func resume(_ id: String, text: String, onResumed: @escaping @Sendable (String) async -> Void) async throws -> String? {
        try await taskActionRepository.resume(id, text: text, onResumed: onResumed)
    }
    
    func beginTakeover(taskID: String) { takeoverService.beginTakeover(taskID: taskID) }
    func setOutcome(_ id: String, _ text: String?) { taskActionRepository.setOutcome(id, text) }

    func acquireEventLease(_ id: String) -> any EventStreamLease { eventStreamRepository.acquire(id) }
    func events(for id: String) -> [TaskEvent] { eventStreamRepository.events(for: id) }
    func eventsPublisher(for id: String) -> AnyPublisher<[TaskEvent], Never> { eventStreamRepository.eventsPublisher(for: id) }
    func items(for id: String) -> [TimelineItem] { eventStreamRepository.items(for: id) }
    func itemsPublisher(for id: String) -> AnyPublisher<[TimelineItem], Never> { eventStreamRepository.itemsPublisher(for: id) }
    func eventsAvailability(for id: String) -> EventAvailability { eventStreamRepository.eventsAvailability(for: id) }
    func eventsAvailabilityPublisher(for id: String) -> AnyPublisher<EventAvailability, Never> {
        eventStreamRepository.eventsAvailabilityPublisher(for: id)
    }

    func activity(for id: String) -> ActivityCounts { eventStreamRepository.activity(for: id) }
    func current(for id: String) -> TimelineItem? { eventStreamRepository.current(for: id) }
    func prompt(for id: String) -> String? { eventStreamRepository.prompt(for: id) }
    /// Display-only (the Raw Events overlay), computed the same way `AppModel.acquireEvents` used
    /// to — `EventStreamRepository` does the identical `/dev/null`-fallback resolution internally but
    /// does not expose it, so it is recomputed here rather than adding a path accessor to that
    /// protocol for one read-only debug label.
    func eventsPath(for id: String) -> String {
        TaskTitle.eventsPath(tasksDirectory: toolEnvironmentRepository.tasksDirectory, taskID: id) ?? "/dev/null"
    }
}
