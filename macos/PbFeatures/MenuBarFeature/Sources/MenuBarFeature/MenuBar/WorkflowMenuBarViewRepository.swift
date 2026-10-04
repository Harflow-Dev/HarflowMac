import MonitorCore
import PbRepository
import SwiftEnvironment

// MARK: - WorkflowMenuBarViewRepository

@MainActor
final class WorkflowMenuBarViewRepository: WorkflowMenuBarUseCase, @unchecked Sendable {
    @GlobalEnvironment(\.workflowRepository) private var repository

    func runs() async throws -> [[String: JSONValue]] {
        try await repository.historySummaries()
    }
}
