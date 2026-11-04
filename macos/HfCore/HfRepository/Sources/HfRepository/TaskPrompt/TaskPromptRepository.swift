import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - TaskPromptRepository

/// One-shot public prompt reads; the caller owns request lifetime and runtime generation.
@Mockable
public protocol TaskPromptRepository: Sendable {
    /// The fence must reject superseded requests, including runtime selection ABA changes.
    /// Callers must recheck their identity before later presentation of a returned value.
    func read(taskID: String, maxBytes: Int,
              operationIsCurrent: @escaping @Sendable () -> Bool) async -> Result<TaskPromptResult, ToolError>
}

// MARK: - NullTaskPromptRepository

/// An unconfigured reader is explicitly unavailable.
public struct NullTaskPromptRepository: TaskPromptRepository {
    public init() {}

    public func read(taskID _: String, maxBytes _: Int,
                     operationIsCurrent _: @escaping @Sendable () -> Bool) async -> Result<TaskPromptResult, ToolError> {
        .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Task prompt unavailable"))
    }
}

// MARK: - GlobalValues

public extension GlobalValues {
    /// Bounded task prompt reader.
    @GlobalEntry var taskPromptRepository: any TaskPromptRepository = NullTaskPromptRepository()
}
