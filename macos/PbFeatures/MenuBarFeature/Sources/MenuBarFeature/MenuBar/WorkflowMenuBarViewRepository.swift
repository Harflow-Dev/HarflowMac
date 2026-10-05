import MonitorCore
import PbRepository
import SwiftEnvironment

// MARK: - WorkflowMenuBarViewRepository

@MainActor
final class WorkflowMenuBarViewRepository: WorkflowMenuBarUseCase, WorkflowMenuBarPageUseCase, @unchecked Sendable {
    @GlobalEnvironment(\.workflowRepository) private var repository

    func activePage() async throws -> HistoryPage {
        try await repository.historyPage(cursor: nil, activeOnly: true, relatedRunID: nil)
    }

    func runs() async throws -> [[String: JSONValue]] {
        try await repository.historySummaries()
    }
}
