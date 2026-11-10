import Combine
import Foundation
import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - TaskContinuationRequest

/// Immutable authority supplied by a caller that captured the selected conversation.
public struct TaskContinuationRequest: Equatable, Sendable {
    public let runtime: QualificationRuntimeToken
    public let conversationID: String
    public let sourceTaskID: String

    public init(runtime: QualificationRuntimeToken, conversationID: String, sourceTaskID: String) {
        self.runtime = runtime
        self.conversationID = conversationID
        self.sourceTaskID = sourceTaskID
    }
}

// MARK: - TaskContinuationCheck

/// Recorded edges are observation evidence, never attribution to the invocation.
public enum TaskContinuationCheck: Equatable, Sendable {
    case notChecked
    case checking
    case recorded(successorTaskIDs: [String])
    case inconclusive
    case failed(QualificationFailure)
}

// MARK: - TaskContinuationAttempt

/// App-session evidence for exactly one invocation; nil outcome means launching.
public struct TaskContinuationAttempt: Equatable, Sendable {
    public let id: UUID
    public let request: TaskContinuationRequest
    public internal(set) var outcome: ConversationLaunchOutcome?
    public internal(set) var check: TaskContinuationCheck
    /// Positive healthy recorded edges survive later failed or cancelled observations.
    public internal(set) var recordedSuccessorTaskIDs: [String] = []
}

// MARK: - TaskContinuationAdmission

/// Admission never implicitly retries an existing invocation.
public enum TaskContinuationAdmission: Equatable, Sendable {
    case started(UUID)
    case existing(UUID)
    case refused(TaskContinuationRefusal)
}

/// Local admission failures; engine eligibility remains engine-owned.
public enum TaskContinuationRefusal: Equatable, Sendable {
    case unavailable, missingIdentity, busy, capacity
    case qualification(QualificationFailure)
}

// MARK: - TaskContinuationRepository

/// Owns Continue invocations and explicit bounded recorded-successor checks.
@Mockable
public protocol TaskContinuationRepository: Sendable {
    func state(for request: TaskContinuationRequest) -> TaskContinuationAttempt?
    /// Initial pulse followed by changed-state invalidations; query the latest state on receipt.
    func changesPublisher() -> AnyPublisher<Void, Never>
    func start(_ request: TaskContinuationRequest) async -> TaskContinuationAdmission
    func check(attemptID: UUID) async
}

// MARK: - NullTaskContinuationRepository

/// Safe default that cannot invoke an engine.
public struct NullTaskContinuationRepository: TaskContinuationRepository {
    public init() {}
    public func state(for _: TaskContinuationRequest) -> TaskContinuationAttempt? { nil }
    public func changesPublisher() -> AnyPublisher<Void, Never> { Just(()).eraseToAnyPublisher() }
    public func start(_: TaskContinuationRequest) async -> TaskContinuationAdmission { .refused(.unavailable) }
    public func check(attemptID _: UUID) async {}
}

public extension GlobalValues {
    /// Shared app-session Continue owner.
    @GlobalEntry var taskContinuationRepository: any TaskContinuationRepository = NullTaskContinuationRepository()
}
