import MonitorCore
import PbRepository
import SwiftEnvironment

// MARK: - WorkflowMenuBarViewRepository

@MainActor
final class WorkflowMenuBarViewRepository: WorkflowMenuBarUseCase, @unchecked Sendable {
    @GlobalEnvironment(\.workflowRepository) private var repository

    func runs() async throws -> [[String: JSONValue]] {
        let result = try await repository.command("list-runs", options: [], positionals: [])
        return result["runs"]?.arrayValue?.compactMap(\.objectValue) ?? []
    }
}
