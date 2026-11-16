import Combine
import Foundation
import HfRepository
@testable import MainWindowFeature
import MonitorCore

// MARK: - SuspendedMessagingUseCase

/// Delegates ordinary screen reads while suspending only the messaging invocation.
@MainActor
final class SuspendedMessagingUseCase: TaskDetailUseCase {
    let base: any TaskDetailUseCase
    let gate = MessagingTestGate()
    init(base: any TaskDetailUseCase) { self.base = base }
    var successorObservationError: String? { base.successorObservationError }
    func continuationOwner() -> any TaskContinuationRepository { base.continuationOwner() }
    func continuationRuntime() -> QualificationRuntimeToken? { base.continuationRuntime() }
    func continuationSupport(runtime: QualificationRuntimeToken) async -> Bool { await base.continuationSupport(runtime: runtime) }
    func callerApprovalUseCase() -> (any CallerApprovalUseCase)? { base.callerApprovalUseCase() }
    func tasksPublisher() -> AnyPublisher<[TaskInfo], Never> { base.tasksPublisher() }
    func hasListedPublisher() -> AnyPublisher<Bool, Never> { base.hasListedPublisher() }
    func titlesPublisher() -> AnyPublisher<[String: String], Never> { base.titlesPublisher() }
    func detail(_ id: String) -> TaskInfo? { base.detail(id) }
    func task(_ id: String) -> TaskInfo? { base.task(id) }
    func title(_ id: String) -> String { base.title(id) }
    func ancestors(of id: String) -> [TaskInfo] { base.ancestors(of: id) }
    func children(of id: String) -> [TaskInfo] { base.children(of: id) }
    func children(ofEach ids: [String]) -> [String: [TaskInfo]] { base.children(ofEach: ids) }
    func siblings(of id: String) -> [TaskInfo] { base.siblings(of: id) }
    func conversationMembers(of id: String) -> [TaskInfo] { base.conversationMembers(of: id) }
    func cancelScope(of id: String) -> Set<String> { base.cancelScope(of: id) }
    func oldestSurvivor(among candidates: Set<String>) -> String? { base.oldestSurvivor(among: candidates) }
    func artifactPage(taskID: String, cursor: String?) async -> Result<TaskArtifactPage, ToolError> { await base.artifactPage(taskID: taskID, cursor: cursor) }
    func statusReadOutcome(_ id: String) -> TaskSnapshotReadOutcome? { base.statusReadOutcome(id) }
    func statusReadChangesPublisher() -> AnyPublisher<Void, Never> { base.statusReadChangesPublisher() }
    func snapshot(_ id: String) -> TaskInfo? { base.snapshot(id) }
    func snapshotsPublisher() -> AnyPublisher<[String: TaskInfo], Never> { base.snapshotsPublisher() }
    func refreshSnapshot(_ id: String) async { await base.refreshSnapshot(id) }
    func isStopping(_ id: String) -> Bool { base.isStopping(id) }
    func stoppingChangesPublisher() -> AnyPublisher<Void, Never> { base.stoppingChangesPublisher() }
    func busyPublisher() -> AnyPublisher<Set<String>, Never> { base.busyPublisher() }
    func outcomesPublisher() -> AnyPublisher<[String: String], Never> { base.outcomesPublisher() }
    @discardableResult func cancel(_ id: String) async throws -> Bool { try await base.cancel(id) }
    @discardableResult func send(_ id: String, text: String) async throws -> Bool { try await base.send(id, text: text) }
    func sendNow(_ id: String, text: String) async throws -> [String: JSONValue] { try await base.sendNow(id, text: text) }
    func messagingSupport(context: MessagingInvocationContext) async -> Bool? { await base.messagingSupport(context: context) }
    func isMessagingContextCurrent(_ context: MessagingInvocationContext) -> Bool { base.isMessagingContextCurrent(context) }
    func messageAttempts() -> [MessagingSubmissionAttempt] { base.messageAttempts() }
    func submitTypedMessage(_ id: String, text: String, now: Bool, acknowledgingUnconfirmed: UUID?,
                            context: MessagingInvocationContext) async throws -> MessagingSubmissionAttempt {
        await gate.park()
        return try await base.submitTypedMessage(id, text: text, now: now, acknowledgingUnconfirmed: acknowledgingUnconfirmed, context: context)
    }

    func messagingInvocationContext() throws -> MessagingInvocationContext { try base.messagingInvocationContext() }
    func cancelMessage(_ id: String, messageID: String, context: MessagingInvocationContext) async throws -> MessagingSubmissionAttempt {
        try await base.cancelMessage(id, messageID: messageID, context: context)
    }

    func isMessagingAttemptCurrent(_ attempt: MessagingSubmissionAttempt) -> Bool { base.isMessagingAttemptCurrent(attempt) }
    @discardableResult func resume(_ id: String, text: String, onResumed: @escaping @Sendable (String) async -> Void) async throws -> String? {
        try await base.resume(id, text: text, onResumed: onResumed)
    }

    func beginTakeover(taskID: String) { base.beginTakeover(taskID: taskID) }
    func allowHarflowTools(backend: String) async throws -> [String: JSONValue] { try await base.allowHarflowTools(backend: backend) }
    func setOutcome(_ id: String, _ text: String?) { base.setOutcome(id, text) }
    func observation(for id: String) -> EventObservationFrame { base.observation(for: id) }
    func observationPublisher(for id: String) -> AnyPublisher<EventObservationFrame, Never> { base.observationPublisher(for: id) }
    @discardableResult func requestObservation(_ action: EventObservationAction, for id: String, scope: EventObservationScope) -> Bool {
        base.requestObservation(action, for: id, scope: scope)
    }

    func requestState(for id: String) -> TaskRequestReadState { base.requestState(for: id) }
    func requestPublisher(for id: String) -> AnyPublisher<TaskRequestReadState, Never> { base.requestPublisher(for: id) }
    func readRequest(for id: String, maxBytes: Int) { base.readRequest(for: id, maxBytes: maxBytes) }
    func recoveredTranscript(for id: String) -> RecoveredTranscriptFrame { base.recoveredTranscript(for: id) }
    func recoveredTranscriptPublisher(for id: String) -> AnyPublisher<RecoveredTranscriptFrame, Never> { base.recoveredTranscriptPublisher(for: id) }
    func observeSuccessors(_ id: String) async throws -> Bool { try await base.observeSuccessors(id) }
    func stopSuccessorObservation() { base.stopSuccessorObservation() }
    func resolveTask(_ id: String) async -> TaskInfo? { await base.resolveTask(id) }
    func conversationHistory(sessionID: String, cursor: String?) async throws -> TaskHistoryPage? {
        try await base.conversationHistory(sessionID: sessionID, cursor: cursor)
    }

    func acquireSummaryLease(_ id: String) -> any EventStreamLease { base.acquireSummaryLease(id) }
    func acquireEventLease(_ id: String) -> any EventStreamLease { base.acquireEventLease(id) }
    func loadMoreSummaryFiles(_ id: String) { base.loadMoreSummaryFiles(id) }
    @discardableResult func loadMoreEvents(_ id: String) -> Bool { base.loadMoreEvents(id) }
    func eventHistory(for id: String) -> EventHistoryState { base.eventHistory(for: id) }
    func eventHistoryPublisher(for id: String) -> AnyPublisher<EventHistoryState, Never> { base.eventHistoryPublisher(for: id) }
    func eventSummary(for id: String) -> EventSummary { base.eventSummary(for: id) }
    func eventSummaryPublisher(for id: String) -> AnyPublisher<EventSummary, Never> { base.eventSummaryPublisher(for: id) }
    func events(for id: String) -> [TaskEvent] { base.events(for: id) }
    func eventsPublisher(for id: String) -> AnyPublisher<[TaskEvent], Never> { base.eventsPublisher(for: id) }
    func items(for id: String) -> [TimelineItem] { base.items(for: id) }
    func itemsPublisher(for id: String) -> AnyPublisher<[TimelineItem], Never> { base.itemsPublisher(for: id) }
    func eventsAvailability(for id: String) -> EventAvailability { base.eventsAvailability(for: id) }
    func eventsAvailabilityPublisher(for id: String) -> AnyPublisher<EventAvailability, Never> { base.eventsAvailabilityPublisher(for: id) }
    func activity(for id: String) -> ActivityCounts { base.activity(for: id) }
    func current(for id: String) -> TimelineItem? { base.current(for: id) }
    func prompt(for id: String) -> String? { base.prompt(for: id) }
    func readChanges(key: TaskChangesKey,
                     operationIsCurrent: @escaping @Sendable () -> Bool) async -> Result<TaskChangesRead<TaskChangesSnapshot>, TaskChangesReadFailure> {
        await base.readChanges(key: key, operationIsCurrent: operationIsCurrent)
    }

    func readChangesPatch(key: TaskChangesKey, selector: TaskChangesSelector,
                          operationIsCurrent: @escaping @Sendable () -> Bool) async -> Result<TaskChangesRead<TaskChangesPatch>, TaskChangesReadFailure> {
        await base.readChangesPatch(key: key, selector: selector, operationIsCurrent: operationIsCurrent)
    }
}

// MARK: - MessagingTestGate

@MainActor
final class MessagingTestGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var arrived = false
    func park() async {
        arrived = true
        await withCheckedContinuation { waiting = $0 }
    }

    func release() { waiting?.resume(); waiting = nil }
}
