import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - TaskArtifactRepository

/// Explicit bounded metadata reads; no artifact content or filesystem access.
@Mockable
public protocol TaskArtifactRepository: Sendable {
    func page(taskID: String, cursor: String?) async -> Result<TaskArtifactPage, ToolError>
}

/// Stateless business read boundary over the CLI transport.
public struct TaskArtifactRepositoryImpl: TaskArtifactRepository {
    private let toolEnvironment: any ToolEnvironmentRepository

    public init(toolEnvironment: any ToolEnvironmentRepository) {
        self.toolEnvironment = toolEnvironment
    }

    public func page(taskID: String, cursor: String?) async -> Result<TaskArtifactPage, ToolError> {
        switch toolEnvironment.ctl() {
        case .success(let client): await client.taskArtifacts(taskID, cursor: cursor)
        case .failure(let error): .failure(error)
        }
    }
}

// MARK: - NullTaskArtifactRepository

/// Unconfigured metadata reads are unavailable rather than empty.
public struct NullTaskArtifactRepository: TaskArtifactRepository {
    public init() {}
    public func page(taskID _: String, cursor _: String?) async -> Result<TaskArtifactPage, ToolError> {
        .failure(.unreadable(tool: "polybridge-ctl", exitCode: 0, stderr: "Artifact metadata unavailable"))
    }
}

// MARK: - GlobalValues

public extension GlobalValues {
    /// Registered artifact metadata repository.
    @GlobalEntry var taskArtifactRepository: any TaskArtifactRepository = NullTaskArtifactRepository()
}
