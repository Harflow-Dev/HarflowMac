//
//  TaskDetailViewRepository.swift
//  MainWindowFeature
//

import Combine
import Foundation
import MonitorCore
import PbRepository
import PbTerminal
import SwiftEnvironment

// MARK: - TaskDetailViewRepository

/// Concrete `TaskDetailUseCase` backed by `TaskListRepository`, `TaskSnapshotRepository`,
/// `TaskActionRepository`, `EventStreamRepository`, `TerminalSessionRegistry`, `TakeoverService`,
/// `GitChangesRepository`, `ToolEnvironmentRepository`, `FilePreviewRepository` and `Scheduling`.
@MainActor
final class TaskDetailViewRepository: TaskDetailUseCase, @unchecked Sendable {
    
    // MARK: - Private Properties
    
    @GlobalEnvironment(\.taskListRepository) private var taskListRepository
    @GlobalEnvironment(\.taskSnapshotRepository) private var taskSnapshotRepository
    @GlobalEnvironment(\.taskActionRepository) private var taskActionRepository
    @GlobalEnvironment(\.eventStreamRepository) private var eventStreamRepository
    @GlobalEnvironment(\.terminalSessionRegistry) private var terminalSessionRegistry
    @GlobalEnvironment(\.takeoverService) private var takeoverService
    @GlobalEnvironment(\.gitChangesRepository) private var gitChangesRepository
    @GlobalEnvironment(\.toolEnvironmentRepository) private var toolEnvironmentRepository
    @GlobalEnvironment(\.filePreviewRepository) private var filePreviewRepository
    @GlobalEnvironment(\.scheduling) private var scheduling
    
    // MARK: - Init
    
    init(
        taskListRepository: (any TaskListRepository)? = nil,
        taskSnapshotRepository: (any TaskSnapshotRepository)? = nil,
        taskActionRepository: (any TaskActionRepository)? = nil,
        eventStreamRepository: (any EventStreamRepository)? = nil,
        terminalSessionRegistry: (any TerminalSessionRegistry)? = nil,
        takeoverService: (any TakeoverService)? = nil,
        gitChangesRepository: (any GitChangesRepository)? = nil,
        toolEnvironmentRepository: (any ToolEnvironmentRepository)? = nil,
        filePreviewRepository: (any FilePreviewRepository)? = nil,
        scheduling: (any Scheduling)? = nil
    ) {
        if let taskListRepository { self.taskListRepository = taskListRepository }
        if let taskSnapshotRepository { self.taskSnapshotRepository = taskSnapshotRepository }
        if let taskActionRepository { self.taskActionRepository = taskActionRepository }
        if let eventStreamRepository { self.eventStreamRepository = eventStreamRepository }
        if let terminalSessionRegistry { self.terminalSessionRegistry = terminalSessionRegistry }
        if let takeoverService { self.takeoverService = takeoverService }
        if let gitChangesRepository { self.gitChangesRepository = gitChangesRepository }
        if let toolEnvironmentRepository { self.toolEnvironmentRepository = toolEnvironmentRepository }
        if let filePreviewRepository { self.filePreviewRepository = filePreviewRepository }
        if let scheduling { self.scheduling = scheduling }
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
    
    func beginTakeover(taskID: String, destination: TakeoverDestination) { takeoverService.beginTakeover(taskID: taskID, destination: destination) }
    
    func sessionsPublisher() -> AnyPublisher<[TerminalSession], Never> { terminalSessionRegistry.sessionsPublisher() }
    func session(forTask id: String) -> TerminalSession? { terminalSessionRegistry.session(forTask: id) }
    func removeSession(_ session: TerminalSession) { terminalSessionRegistry.remove(session) }
    
    func acquireEventLease(_ id: String) -> any EventStreamLease { eventStreamRepository.acquire(id) }
    func events(for id: String) -> [TaskEvent] { eventStreamRepository.events(for: id) }
    func eventsPublisher(for id: String) -> AnyPublisher<[TaskEvent], Never> { eventStreamRepository.eventsPublisher(for: id) }
    func items(for id: String) -> [TimelineItem] { eventStreamRepository.items(for: id) }
    func itemsPublisher(for id: String) -> AnyPublisher<[TimelineItem], Never> { eventStreamRepository.itemsPublisher(for: id) }
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
    
    func gitChanges(repo: String, baseCommit: String?, startDirty: Bool?) async -> GitChanges {
        await gitChangesRepository.changes(repo: repo, baseCommit: baseCommit, startDirty: startDirty, environment: toolEnvironmentRepository.environment())
    }
    
    @discardableResult
    func schedule(after interval: TimeInterval, execute work: @escaping @Sendable () -> Void) -> AnyCancellable {
        scheduling.schedule(after: interval, execute: work)
    }
    
    func previewFile(repo: String, path: String) async -> FilePreviewResult {
        await filePreviewRepository.preview(repo: repo, path: path)
    }
}
