import HfRepository
import MonitorCore
import SwiftEnvironment

// MARK: - WorkflowLibraryViewRepository

@MainActor final class WorkflowLibraryViewRepository: WorkflowLibraryUseCase {
    @GlobalEnvironment(\.approvalResponseOwner) private var observation
    @GlobalEnvironment(\.workflowRepository) private var workflows

    func context() throws -> WorkflowResponseContext {
        let context = try observation.context()
        return WorkflowResponseContext(runtime: context.runtime, epoch: context.epoch)
    }

    func isCurrent(_ context: WorkflowResponseContext) -> Bool {
        observation.isCurrent(.init(runtime: context.runtime, epoch: context.epoch))
    }

    func list(context: WorkflowResponseContext) async throws -> [String: JSONValue] {
        let owner = observation
        let captured = ApprovalResponseContext(runtime: context.runtime, epoch: context.epoch)
        return try await workflows.command("list", options: ["--monitor-view"], positionals: [], runtime: context.runtime,
                                           isCurrent: { owner.isCurrent(captured) })
    }
}
