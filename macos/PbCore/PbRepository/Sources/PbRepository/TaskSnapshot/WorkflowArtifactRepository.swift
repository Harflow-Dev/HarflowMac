import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - WorkflowArtifactRepository

/// Explicit bounded metadata reads; no artifact content or filesystem access.
@Mockable
public protocol WorkflowArtifactRepository: Sendable {
    func page(runID: String, executionID: String?, cursor: String?) async -> Result<WorkflowArtifactPage, ToolError>
}

/// Stateless business read boundary over the CLI transport.
public struct WorkflowArtifactRepositoryImpl: WorkflowArtifactRepository {
    private let toolEnvironment: any ToolEnvironmentRepository

    public init(toolEnvironment: any ToolEnvironmentRepository) {
        self.toolEnvironment = toolEnvironment
    }

    public func page(runID: String, executionID: String?, cursor: String?) async -> Result<WorkflowArtifactPage, ToolError> {
        switch toolEnvironment.ctl() {
        case .success(let client): await client.workflowArtifacts(runId: runID, executionId: executionID, cursor: cursor)
        case .failure(let error): .failure(error)
        }
    }
}

// MARK: - NullWorkflowArtifactRepository

/// Unconfigured metadata reads are unavailable rather than empty.
public struct NullWorkflowArtifactRepository: WorkflowArtifactRepository {
    public init() {}
    public func page(runID _: String, executionID _: String?, cursor _: String?) async -> Result<WorkflowArtifactPage, ToolError> {
        .failure(.unreadable(tool: "polybridge-ctl", exitCode: 0, stderr: "Artifact metadata unavailable"))
    }
}

// MARK: - GlobalValues

public extension GlobalValues {
    /// Registered artifact metadata repository.
    @GlobalEntry var workflowArtifactRepository: any WorkflowArtifactRepository = NullWorkflowArtifactRepository()
}
