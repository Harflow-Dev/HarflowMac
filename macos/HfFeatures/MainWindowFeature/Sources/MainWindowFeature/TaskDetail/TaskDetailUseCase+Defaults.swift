import Combine
import HfRepository
import MonitorCore

// MARK: - TaskDetailUseCase Defaults

extension TaskDetailUseCase {
    func callerApprovalUseCase() -> (any CallerApprovalUseCase)? { nil }
    func artifactPage(taskID _: String, cursor _: String?) async -> Result<TaskArtifactPage, ToolError> {
        .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Artifact metadata unavailable"))
    }

    func readChanges(key: TaskChangesKey, operationIsCurrent _: @escaping @Sendable () -> Bool)
        async -> Result<TaskChangesRead<TaskChangesSnapshot>, TaskChangesReadFailure> {
        .failure(TaskChangesReadFailure(key: key, outcome: .failed(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Task changes unavailable"))))
    }

    func readChangesPatch(key: TaskChangesKey, selector _: TaskChangesSelector, operationIsCurrent _: @escaping @Sendable () -> Bool)
        async -> Result<TaskChangesRead<TaskChangesPatch>, TaskChangesReadFailure> {
        .failure(TaskChangesReadFailure(key: key, outcome: .failed(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Task changes unavailable"))))
    }

    var successorObservationError: String? { nil }
    func observeSuccessors(_: String) async throws -> Bool { false }
    func stopSuccessorObservation() {}
    func resolveTask(_ id: String) async -> TaskInfo? { task(id) }
    func conversationHistory(sessionID _: String, cursor _: String?) async throws -> TaskHistoryPage? { nil }
    func acquireSummaryLease(_ id: String) -> any EventStreamLease { acquireEventLease(id) }
    func loadMoreSummaryFiles(_: String) {}
    @discardableResult func loadMoreEvents(_: String) -> Bool { false }
    func eventHistory(for _: String) -> EventHistoryState { EventHistoryState() }
    func eventHistoryPublisher(for id: String) -> AnyPublisher<EventHistoryState, Never> { Just(eventHistory(for: id)).eraseToAnyPublisher() }
    func eventSummary(for id: String) -> EventSummary {
        var builder = EventSummaryBuilder()
        builder.append(events(for: id))
        builder.setAvailability(eventsAvailability(for: id))
        return builder.summary
    }

    func eventSummaryPublisher(for id: String) -> AnyPublisher<EventSummary, Never> { Just(eventSummary(for: id)).eraseToAnyPublisher() }
}

// MARK: - TaskDetailViewModel Defaults

extension TaskDetailViewModel {
    var isStopping: Bool { false }
    var isStatusUnavailable: Bool { false }
    var hasStatusAuthority: Bool { true }
    var isSettling: Bool { false }
}
