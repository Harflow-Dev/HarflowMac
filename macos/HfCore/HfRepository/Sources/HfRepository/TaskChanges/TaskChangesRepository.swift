import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - TaskChangesKey

/// Identity of one read: the task as requested and the caller's generation for it.
public struct TaskChangesKey: Equatable, Hashable, Sendable {
    public let taskID: String
    /// Caller-owned epoch (selection, runtime or refresh); echoed unchanged so a stale result is recognisable.
    public let generation: UInt64

    public init(taskID: String, generation: UInt64) {
        self.taskID = taskID
        self.generation = generation
    }
}

// MARK: - TaskChangesRead

/// A successful read keyed by the request that produced it.
public struct TaskChangesRead<Value: Equatable & Sendable>: Equatable, Sendable {
    public let key: TaskChangesKey
    public let value: Value

    public init(key: TaskChangesKey, value: Value) {
        self.key = key
        self.value = value
    }
}

// MARK: - TaskChangesReadFailure

/// A failed read, keyed like a success. A superseded read is not an error state and is never reported.
public struct TaskChangesReadFailure: Error, Equatable, Sendable {
    /// Why the read produced no value.
    public enum Outcome: Equatable, Sendable {
        /// The caller's fence or the selected runtime changed; the result must be dropped.
        case superseded
        case failed(ToolError)
        /// This read stopped at its own request or time bound (see ``ClientBound``); the stored changes may be complete.
        /// Only the read budget produces it. A per-command transport timeout stays `failed(.timedOut)`.
        case clientBound(ClientBound)
    }

    /// Which of the read's own limits stopped it.
    public enum ClientBound: Equatable, Sendable {
        /// The 120 second wall-clock deadline passed before another request.
        case deadline
        /// The 64 request budget was spent.
        case requestBudget
    }

    public let key: TaskChangesKey
    public let outcome: Outcome

    public init(key: TaskChangesKey, outcome: Outcome) {
        self.key = key
        self.outcome = outcome
    }
}

// MARK: - TaskChangesRepository

/// Stored repository differences of a task, read through the public `task-changes` command only.
/// Reads are one-shot and bounded (64 requests and 120 seconds per read, across restarts). The deadline
/// is checked before each request, so a read can overrun it by one in-flight probe and command. The caller
/// reads `capture.state` and `capture.reason` and decides when to read again. Diff text is returned to
/// the caller and never cached or logged here.
@Mockable
public protocol TaskChangesRepository: Sendable {
    /// Reads every listing page, restarting from the first page when a cursor expires.
    /// The fence must reject superseded requests, including runtime selection ABA changes; callers
    /// recheck their own generation before presenting a returned value.
    func readListing(key: TaskChangesKey,
                     operationIsCurrent: @escaping @Sendable () -> Bool) async -> Result<TaskChangesRead<TaskChangesSnapshot>, TaskChangesReadFailure>

    /// Reads every chunk of one row's patch, restarting from the first chunk when a cursor expires.
    func readPatch(key: TaskChangesKey, selector: TaskChangesSelector,
                   operationIsCurrent: @escaping @Sendable () -> Bool) async -> Result<TaskChangesRead<TaskChangesPatch>, TaskChangesReadFailure>
}

// MARK: - NullTaskChangesRepository

/// An unconfigured reader is explicitly unavailable.
public struct NullTaskChangesRepository: TaskChangesRepository {
    public init() {}

    private static func unavailable(_ key: TaskChangesKey) -> TaskChangesReadFailure {
        TaskChangesReadFailure(key: key, outcome: .failed(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Task changes unavailable")))
    }

    public func readListing(key: TaskChangesKey,
                            operationIsCurrent _: @escaping @Sendable () -> Bool)
        async -> Result<TaskChangesRead<TaskChangesSnapshot>, TaskChangesReadFailure> {
        .failure(Self.unavailable(key))
    }

    public func readPatch(key: TaskChangesKey, selector _: TaskChangesSelector,
                          operationIsCurrent _: @escaping @Sendable () -> Bool) async -> Result<TaskChangesRead<TaskChangesPatch>, TaskChangesReadFailure> {
        .failure(Self.unavailable(key))
    }
}

// MARK: - GlobalValues

public extension GlobalValues {
    /// Stored task changes reader.
    @GlobalEntry var taskChangesRepository: any TaskChangesRepository = NullTaskChangesRepository()
}
