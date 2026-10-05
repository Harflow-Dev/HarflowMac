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

    private let builderRunID: String?
    private var relatedMembers: [String: TaskInfo] = [:]
    @GlobalEnvironment(\.workflowRepository) private var workflowRepository
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
        toolEnvironmentRepository: (any ToolEnvironmentRepository)? = nil,
        builderRunID: String? = nil,
        workflowRepository: (any WorkflowRepository)? = nil
    ) {
        self.builderRunID = builderRunID
        if let workflowRepository { self.workflowRepository = workflowRepository }
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
    func detail(_ id: String) -> TaskInfo? {
        guard let listed = taskListRepository.task(id) else { return taskListRepository.detail(id) }
        return WorkflowNodePresentation.merged(taskListRepository.detail(id), with: listed)
    }

    func task(_ id: String) -> TaskInfo? { taskListRepository.task(id) }
    func title(_ id: String) -> String { taskListRepository.title(id) }
    func ancestors(of id: String) -> [TaskInfo] { Lineage.ancestors(of: id, in: taskListRepository.tasks) }
    func children(of id: String) -> [TaskInfo] { Lineage.children(of: id, in: taskListRepository.tasks) }
    /// One shared `LineageIndex` answering every id's children (Codex review round 1, finding 1) —
    /// `TaskDetailVM.allConversationChildren()`'s own need, several members queried in one recompute,
    /// instead of `children(of:)` once per member each rebuilding the index from scratch.
    func children(ofEach ids: [String]) -> [String: [TaskInfo]] {
        let index = LineageIndex(taskListRepository.tasks)
        return Dictionary(ids.map { ($0, index.children(of: $0)) }, uniquingKeysWith: { first, _ in first })
    }

    /// The current parent's other children (F4-38's lineage list) — every child of the nearest
    /// ancestor, current task included, or none for a root task. `Lineage.siblings(of:in:)` builds
    /// one `LineageIndex` and reads ancestors/children off it, rather than this call rebuilding the
    /// index twice over (Monitor piece 11).
    func siblings(of id: String) -> [TaskInfo] { Lineage.siblings(of: id, in: taskListRepository.tasks) }

    func conversationMembers(of id: String) -> [TaskInfo] {
        WorkflowOrchestratorConversation.members(containing: id, in: conversationInventory)
            ?? Lineage.conversation(containing: id, in: conversationInventory)?.members ?? []
    }

    func cancelScope(of id: String) -> Set<String> { Lineage.cancelScope(of: id, in: taskListRepository.tasks) }
    func oldestSurvivor(among candidates: Set<String>) -> String? { Lineage.oldestSurvivor(among: candidates, in: taskListRepository.tasks) }

    func snapshot(_ id: String) -> TaskInfo? { taskSnapshotRepository.snapshot(id) }
    func snapshotsPublisher() -> AnyPublisher<[String: TaskInfo], Never> { taskSnapshotRepository.snapshotsPublisher() }
    func refreshSnapshot(_ id: String) async { await taskSnapshotRepository.refresh(id) }
    
    func busyPublisher() -> AnyPublisher<Set<String>, Never> { taskActionRepository.busyPublisher() }
    func outcomesPublisher() -> AnyPublisher<[String: String], Never> { taskActionRepository.outcomesPublisher() }
    
    @discardableResult func cancel(_ id: String) async throws -> Bool { try await taskActionRepository.cancel(id) }
    @discardableResult func send(_ id: String, text: String) async throws -> Bool {
        if builderRunID != nil { _ = try await builderFollowup(id, text: text); return true }
        return try await taskActionRepository.send(id, text: text)
    }

    @discardableResult func resume(_ id: String, text: String, onResumed: @escaping @Sendable (String) async -> Void) async throws -> String? {
        if builderRunID != nil {
            return try await builderFollowup(id, text: text)
        }
        return try await taskActionRepository.resume(id, text: text, onResumed: onResumed)
    }
    
    private func builderFollowup(_ id: String, text: String) async throws -> String? {
        guard let builderRunID else { return nil }
        let response = try await workflowRepository.command("builder-followup", options: ["--prompt=\(text)"], positionals: [builderRunID])
        let state = response["status"]?.stringValue ?? "queued"
        taskActionRepository.setOutcome(id, state == "queued_next_turn" ? "Queued for the next builder turn." : "Queued for the workflow builder.")
        await taskListRepository.refresh()
        return nil
    }

    func allowPolybridgeTools(backend: String) async throws -> [String: JSONValue] {
        let ctl = try toolEnvironmentRepository.ctl().get()
        return try await ctl.mcpAllowlist(backend: backend, allow: "polybridge/*").get()
    }

    func beginTakeover(taskID: String) { takeoverService.beginTakeover(taskID: taskID) }
    func setOutcome(_ id: String, _ text: String?) { taskActionRepository.setOutcome(id, text) }

    func acquireEventLease(_ id: String) -> any EventStreamLease { eventStreamRepository.acquire(id) }
    private var conversationInventory: [TaskInfo] {
        var tasks = relatedMembers
        for task in taskListRepository.tasks { tasks[task.taskID] = task }
        return Array(tasks.values)
    }

    func resolveTask(_ id: String) async -> TaskInfo? {
        let task = await taskListRepository.resolve(id)
        if let task { relatedMembers[id] = task }
        return task
    }

    func conversationHistory(sessionID: String, cursor: String?) async throws -> TaskHistoryPage? {
        let page = try await taskListRepository.conversationPage(sessionID: sessionID, cursor: cursor, limit: 100)
        for task in page.items { relatedMembers[task.taskID] = task }
        return page
    }

    func acquireSummaryLease(_ id: String) -> any EventStreamLease { eventStreamRepository.acquireSummary(id) }
    func loadMoreSummaryFiles(_ id: String) { eventStreamRepository.loadMoreSummaryFiles(id) }
    func loadMoreEvents(_ id: String) { eventStreamRepository.loadMore(id) }
    func eventHistory(for id: String) -> EventHistoryState { eventStreamRepository.history(for: id) }
    func eventHistoryPublisher(for id: String) -> AnyPublisher<EventHistoryState, Never> { eventStreamRepository.historyPublisher(for: id) }
    func eventSummary(for id: String) -> EventSummary { eventStreamRepository.summary(for: id) }
    func eventSummaryPublisher(for id: String) -> AnyPublisher<EventSummary, Never> { eventStreamRepository.summaryPublisher(for: id) }
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
