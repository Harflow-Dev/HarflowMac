//
//  TaskDetailViewRepository.swift
//  MainWindowFeature
//

import Combine
import Foundation
import HfRepository
import MonitorCore
import SwiftEnvironment

// MARK: - TaskDetailViewRepository

/// Concrete `TaskDetailUseCase` backed by `TaskListRepository`, `TaskSnapshotRepository`,
/// `TaskActionRepository`, `EventStreamRepository`, `TakeoverService` and `ToolEnvironmentRepository`.
@MainActor
final class TaskDetailViewRepository: TaskDetailUseCase, @unchecked Sendable {

    // MARK: - Private Properties

    @GlobalEnvironment(\.taskArtifactRepository) private var taskArtifactRepository
    private let builderRunID: String?
    private var relatedMembers: [String: TaskInfo] = [:]
    private var successorMembers: [String: TaskInfo] = [:]
    private var successorRefreshMembers: [String: TaskInfo] = [:]
    private var successorRuntime: QualificationRuntimeToken?
    private var successorEpoch = UUID()
    private var successorEnabled = false
    private(set) var successorObservationError: String?
    private var successorTask: Task<Void, Never>?
    private var successorIncomplete = false
    private var successorBusy = false
    private var successorFrontier: [(String, String?)] = []
    private var successorVisited: Set<String> = []
    private var successorCursors: [String: Set<String>] = [:]
    private let successorChanges = PassthroughSubject<[TaskInfo], Never>()
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
        taskArtifactRepository: (any TaskArtifactRepository)? = nil,
        builderRunID: String? = nil,
        workflowRepository: (any WorkflowRepository)? = nil
    ) {
        self.builderRunID = builderRunID
        if let taskArtifactRepository { self.taskArtifactRepository = taskArtifactRepository }
        if let workflowRepository { self.workflowRepository = workflowRepository }
        if let taskListRepository { self.taskListRepository = taskListRepository }
        if let taskSnapshotRepository { self.taskSnapshotRepository = taskSnapshotRepository }
        if let taskActionRepository { self.taskActionRepository = taskActionRepository }
        if let eventStreamRepository { self.eventStreamRepository = eventStreamRepository }
        if let takeoverService { self.takeoverService = takeoverService }
        if let toolEnvironmentRepository { self.toolEnvironmentRepository = toolEnvironmentRepository }
    }
    
    func artifactPage(taskID: String, cursor: String?) async -> Result<TaskArtifactPage, ToolError> {
        await taskArtifactRepository.page(taskID: taskID, cursor: cursor)
    }

    func callerApprovalUseCase() -> (any CallerApprovalUseCase)? {
        CallerApprovalRepository(environment: toolEnvironmentRepository)
    }

    // MARK: - TaskDetailUseCase Methods
    
    func tasksPublisher() -> AnyPublisher<[TaskInfo], Never> { taskListRepository.tasksPublisher().merge(with: successorChanges).eraseToAnyPublisher() }
    func hasListedPublisher() -> AnyPublisher<Bool, Never> { taskListRepository.hasListedPublisher() }
    func titlesPublisher() -> AnyPublisher<[String: String], Never> { taskListRepository.titlesPublisher() }
    func detail(_ id: String) -> TaskInfo? {
        synchronizeSuccessorRuntime()
        guard let listed = taskListRepository.task(id) else { return successorMembers[id] ?? relatedMembers[id] ?? taskListRepository.detail(id) }
        return WorkflowNodePresentation.merged(taskListRepository.detail(id), with: listed)
    }

    func task(_ id: String) -> TaskInfo? {
        synchronizeSuccessorRuntime()
        return taskListRepository.task(id) ?? successorMembers[id] ?? relatedMembers[id]
    }

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
        try await taskActionRepository.send(id, text: text)
    }

    func sendNow(_ id: String, text: String) async throws -> [String: JSONValue] {
        let client = try toolEnvironmentRepository.ctl().get()
        let result = try await client.sendNow(id, text: text).get()
        taskActionRepository.setOutcome(id, WorkMessageOutcome.describe(result))
        await taskSnapshotRepository.refresh(id)
        await taskListRepository.refresh()
        return result
    }

    func cancelMessage(_ id: String, messageID: String) async throws {
        let client = try toolEnvironmentRepository.ctl().get()
        _ = try await client.cancelMessage(id, messageID: messageID).get()
        taskActionRepository.setOutcome(id, "Queued message cancelled.")
        await taskSnapshotRepository.refresh(id)
    }

    @discardableResult func resume(_ id: String, text: String, onResumed: @escaping @Sendable (String) async -> Void) async throws -> String? {
        if builderRunID != nil {
            return try await builderFollowup(id, text: text)
        }
        let epoch = successorEpoch
        let acknowledged = try await taskActionRepository.resume(id, text: text, onResumed: onResumed)
        if acknowledged != nil, successorEnabled, successorEpoch == epoch {
            // Observation never changes the acknowledged mutation outcome or retries it.
            successorTask?.cancel()
            successorTask = Task { [weak self] in
                guard let self, successorEpoch == epoch, successorEnabled else { return }
                do {
                    let partial = try await observeSuccessors(id)
                    guard successorEpoch == epoch, !Task.isCancelled else { return }
                    successorObservationError = partial ? "Conversation history is incomplete. Retry to continue." : nil
                } catch {
                    guard successorEpoch == epoch, !Task.isCancelled else { return }
                    successorObservationError = "Conversation history could not be loaded. Retry to continue."
                }
                successorChanges.send(conversationInventory.sorted { $0.taskID < $1.taskID })
            }
        }
        return acknowledged
    }
    
    private func builderFollowup(_ id: String, text: String) async throws -> String? {
        guard let builderRunID else { return nil }
        let response = try await workflowRepository.command("builder-followup", options: ["--prompt=\(text)"], positionals: [builderRunID])
        let state = response["status"]?.stringValue ?? "queued"
        taskActionRepository.setOutcome(id, state == "queued_next_turn" ? "Queued for the next builder turn." : "Queued for the workflow builder.")
        await taskListRepository.refresh()
        return nil
    }

    func allowHarflowTools(backend: String) async throws -> [String: JSONValue] {
        let ctl = try toolEnvironmentRepository.ctl().get()
        return try await ctl.mcpAllowlist(backend: backend, allow: "harflow/*").get()
    }

    func beginTakeover(taskID: String) { takeoverService.beginTakeover(taskID: taskID) }
    func setOutcome(_ id: String, _ text: String?) { taskActionRepository.setOutcome(id, text) }

    func observation(for id: String) -> EventObservationFrame { eventStreamRepository.observation(for: id) }
    func observationPublisher(for id: String) -> AnyPublisher<EventObservationFrame, Never> { eventStreamRepository.observationPublisher(for: id) }
    @discardableResult func requestObservation(_ action: EventObservationAction, for id: String, scope: EventObservationScope) -> Bool {
        eventStreamRepository.requestObservation(action: action, for: id, scope: scope)
    }

    func requestState(for id: String) -> TaskRequestReadState { eventStreamRepository.requestState(for: id) }
    func requestPublisher(for id: String) -> AnyPublisher<TaskRequestReadState, Never> { eventStreamRepository.requestPublisher(for: id) }
    func readRequest(for id: String, maxBytes: Int) { eventStreamRepository.readRequest(for: id, maxBytes: maxBytes) }
    func recoveredTranscript(for id: String) -> RecoveredTranscriptFrame { eventStreamRepository.recoveredTranscript(for: id) }
    func recoveredTranscriptPublisher(for id: String) -> AnyPublisher<RecoveredTranscriptFrame, Never> {
        eventStreamRepository.recoveredTranscriptPublisher(for: id)
    }

    func acquireEventLease(_ id: String) -> any EventStreamLease { eventStreamRepository.acquire(id) }
    private var conversationInventory: [TaskInfo] {
        synchronizeSuccessorRuntime()
        var tasks = relatedMembers
        tasks.merge(successorMembers) { _, successor in successor }
        for task in taskListRepository.tasks { tasks[task.taskID] = task }
        return Array(tasks.values)
    }

    private func synchronizeSuccessorRuntime() {
        let current = (try? toolEnvironmentRepository.ctl().get()).map(QualificationRuntimeToken.init(client:))
        guard current != successorRuntime else { return }
        stopSuccessorObservation()
        successorRuntime = current
    }

    func stopSuccessorObservation() {
        successorEpoch = UUID()
        successorTask?.cancel()
        successorTask = nil
        successorIncomplete = false
        successorObservationError = nil
        successorEnabled = false
        successorBusy = false
        successorFrontier = []
        successorVisited = []
        successorCursors = [:]
        relatedMembers = [:]
        successorMembers = [:]
        successorRefreshMembers = [:]
    }

    /// A selected-surface serial frontier. Empty observations only concern recorded tasks.
    func observeSuccessors(_ id: String) async throws -> Bool {
        guard successorEnabled else { throw CancellationError() }
        synchronizeSuccessorRuntime()
        successorEnabled = true
        guard !successorBusy else { return true }
        guard let runtime = successorRuntime else { throw QualificationSessionError.runtimeChanged }
        let epoch = successorEpoch
        successorBusy = true
        defer { if successorEpoch == epoch { successorBusy = false } }
        if successorFrontier.isEmpty {
            successorIncomplete = false
            successorRefreshMembers = [:]
            successorVisited = []
            successorCursors = [:]
            successorFrontier = [(id, nil)]
        }
        var pages = 0
        var rows = 0
        while !successorFrontier.isEmpty, pages < 4, rows < 400 {
            let (predecessor, cursor) = successorFrontier[0]
            if !successorVisited.contains(predecessor), successorVisited.count >= 32 { return markSuccessorIncomplete() }
            successorVisited.insert(predecessor)
            let response = try await taskListRepository.successorPage(predecessorTaskID: predecessor, cursor: cursor, runtime: runtime)
            synchronizeSuccessorRuntime()
            guard !Task.isCancelled, successorEpoch == epoch, successorRuntime == runtime else {
                throw QualificationSessionError.runtimeChanged
            }
            let page = response.history
            let count = page.items.count + page.relatedItems.count
            guard rows + count <= 400 else { return markSuccessorIncomplete() }
            pages += 1
            rows += count
            try applySuccessorPage(response, predecessor: predecessor, cursor: cursor)
            if page.page.bootstrapPending || !page.page.catalogState.isReady { return markSuccessorIncomplete() }
        }
        return finishSuccessorCycle()
    }

    private func applySuccessorPage(_ response: TaskSuccessorPage, predecessor: String, cursor: String?) throws {
        let page = response.history
        let health = page.page
        let incompleteHealth = response.readinessUnknown || health.bootstrapPending || health.historyIncomplete
            || health.authorityIncomplete || !health.catalogState.isReady
        successorIncomplete = successorIncomplete || incompleteHealth
        if let next = health.nextCursor, health.hasMore {
            guard next != cursor, successorCursors[predecessor, default: []].insert(next).inserted else {
                throw ToolError.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Recorded successor cursor did not advance")
            }
        }
        successorFrontier.removeFirst()
        if health.hasMore, let next = health.nextCursor { successorFrontier.insert((predecessor, next), at: 0) }
        let changed = mergeSuccessorRows(page.items + page.relatedItems)
        enqueueSuccessors(page.items)
        if changed { successorChanges.send(conversationInventory.sorted { $0.taskID < $1.taskID }) }
    }

    private func mergeSuccessorRows(_ tasks: [TaskInfo]) -> Bool {
        var changed = false
        for task in tasks {
            guard successorRefreshMembers[task.taskID] != nil || successorRefreshMembers.count < 400 else {
                successorIncomplete = true
                continue
            }
            successorRefreshMembers[task.taskID] = task
            guard successorMembers[task.taskID] != nil || successorMembers.count < 800 else {
                successorIncomplete = true
                continue
            }
            if successorMembers[task.taskID] != task { successorMembers[task.taskID] = task; changed = true }
        }
        return changed
    }

    private func enqueueSuccessors(_ tasks: [TaskInfo]) {
        for task in tasks where !successorVisited.contains(task.taskID) && !successorFrontier.contains(where: { $0.0 == task.taskID }) {
            if successorVisited.count + successorFrontier.count < 32 {
                successorFrontier.append((task.taskID, nil))
            } else { successorIncomplete = true }
        }
    }

    private func finishSuccessorCycle() -> Bool {
        let incomplete = successorIncomplete || !successorFrontier.isEmpty
        successorObservationError = incomplete ? "Conversation history is incomplete. Retry to continue." : nil
        if !incomplete, successorMembers != successorRefreshMembers {
            successorMembers = successorRefreshMembers
            successorChanges.send(conversationInventory.sorted { $0.taskID < $1.taskID })
        }
        return incomplete
    }

    private func markSuccessorIncomplete() -> Bool {
        successorIncomplete = true
        successorObservationError = "Conversation history is incomplete. Retry to continue."
        return true
    }

    func resolveTask(_ id: String) async -> TaskInfo? {
        synchronizeSuccessorRuntime()
        successorEnabled = true
        let epoch = successorEpoch
        let task = await taskListRepository.resolve(id)
        synchronizeSuccessorRuntime()
        guard !Task.isCancelled, epoch == successorEpoch else { return nil }
        if let task { relatedMembers[task.taskID] = task }
        return task
    }

    func conversationHistory(sessionID: String, cursor: String?) async throws -> TaskHistoryPage? {
        synchronizeSuccessorRuntime()
        let epoch = successorEpoch
        let page = try await taskListRepository.conversationPage(sessionID: sessionID, cursor: cursor, limit: 100)
        synchronizeSuccessorRuntime()
        guard !Task.isCancelled, successorEpoch == epoch else { throw QualificationSessionError.runtimeChanged }
        for task in page.items { relatedMembers[task.taskID] = task }
        return page
    }

    func acquireSummaryLease(_ id: String) -> any EventStreamLease { eventStreamRepository.acquireSummary(id) }
    func loadMoreSummaryFiles(_ id: String) { eventStreamRepository.loadMoreSummaryFiles(id) }
    @discardableResult func loadMoreEvents(_ id: String) -> Bool { eventStreamRepository.loadMore(id) }
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
}
