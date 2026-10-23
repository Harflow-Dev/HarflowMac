import Combine
import Foundation
import HfCommon
import HfRepository
import HfUI
import HfUtilities
import Mockable
import MonitorCore

// MARK: - ParallelUseCase

/// Data and action boundary for Parallel conversation presentation.
@Mockable
@MainActor
protocol ParallelUseCase: Sendable {
    func tasksPublisher() -> AnyPublisher<[TaskInfo], Never>
    func snapshotsPublisher() -> AnyPublisher<[String: TaskInfo], Never>
    func busyPublisher() -> AnyPublisher<Set<String>, Never>
    func outcomesPublisher() -> AnyPublisher<[String: String], Never>
    func titlesPublisher() -> AnyPublisher<[String: String], Never>
    /// Returns the fresh listing entry.
    func task(_ id: String) -> TaskInfo?
    func title(_ taskID: String) -> String
    func acquireEventLease(_ taskID: String) -> any EventStreamLease
    func events(for taskID: String) -> [TaskEvent]
    func items(for taskID: String) -> [TimelineItem]
    func itemsPublisher(for taskID: String) -> AnyPublisher<[TimelineItem], Never>
    func prompt(for taskID: String) -> String?
    func eventHistory(for taskID: String) -> EventHistoryState
    func eventHistoryPublisher(for taskID: String) -> AnyPublisher<EventHistoryState, Never>
    func conversationHistory(sessionID: String, cursor: String?) async throws -> TaskHistoryPage?
    @discardableResult func loadMoreEvents(_ taskID: String) -> Bool
    /// Distinguishes pending activity from a missing or unreadable log.
    func eventsAvailability(for taskID: String) -> EventAvailability
    func eventsAvailabilityPublisher(for taskID: String) -> AnyPublisher<EventAvailability, Never>
    func runningInSubtrees(of ids: [String]) -> [String]
    func cancelAll(_ ids: [String]) async
    func setOutcome(_ id: String, _ text: String?)
    /// Starts Terminal takeover synchronously before routing.
    func beginTakeover(taskID: String)
}

// MARK: - ParallelRouting

@Mockable
@MainActor
protocol ParallelRouting: Sendable {
    func selectTask(_ taskID: String)
}
