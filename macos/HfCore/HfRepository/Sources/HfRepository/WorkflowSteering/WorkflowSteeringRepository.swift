import Foundation
import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - WorkflowSteeringObservation

/// Exact displayed status bound to one local runtime generation and authoritative read.
public struct WorkflowSteeringObservation: Equatable, Sendable {
    public let status: WorkflowSteeringStatus
    public let runtime: QualificationRuntimeToken
    public let generation: UInt64
    public let readOrdinal: UInt64
    let id: UUID
}

// MARK: - WorkflowSteeringAttempt

/// App-session invocation evidence survives its originating UI and runtime selection.
public struct WorkflowSteeringAttempt: Equatable, Sendable {
    public let id: UUID
    public let request: WorkflowSteeringRequest
    public let runtime: QualificationRuntimeToken
    public let generation: UInt64
    public internal(set) var outcome: WorkflowSteeringOutcome?
    public internal(set) var admissionHistory: WorkflowSteeringHistoryItem?
    public internal(set) var refusalEstablished: Bool
    var settledReadOrdinal: UInt64?

    /// Positive receipt or matching requested history establishes admission, never execution.
    public var isAdmitted: Bool {
        if admissionHistory != nil { return true }
        if case .admitted = outcome { return true }
        return false
    }

    /// No positive admission or nonadmission evidence has settled this invocation.
    public var isIndeterminate: Bool {
        guard !isAdmitted, !refusalEstablished else { return false }
        if case .indeterminate = outcome { return true }
        return false
    }
}

// MARK: - WorkflowSteeringRepository

/// Root public steering and shared per-invocation ownership. There is no polling or replay operation.
@Mockable
public protocol WorkflowSteeringRepository: Sendable {
    func observation(rootID: String) async throws -> WorkflowSteeringObservation
    func history(observation: WorkflowSteeringObservation, cursor: String?) async throws -> WorkflowSteeringHistoryPage
    func perform(action: WorkflowSteeringAction, text: String?, observation: WorkflowSteeringObservation) async throws -> WorkflowSteeringAttempt
    func attempts(rootID: String) -> [WorkflowSteeringAttempt]
    func isCurrent(_ observation: WorkflowSteeringObservation) -> Bool
}

// MARK: - WorkflowSteeringAdmissionError

/// Conservative local admission failures, distinct from an engine command outcome.
public enum WorkflowSteeringAdmissionError: Error, Equatable, Sendable {
    case unsupported, runtimeChanged, staleObservation, busy, unresolved, capacity
}

// MARK: - NullWorkflowSteeringRepository

/// Explicit unsupported default never dispatches or invents empty success.
public struct NullWorkflowSteeringRepository: WorkflowSteeringRepository {
    public init() {}
    public func observation(rootID _: String) async throws -> WorkflowSteeringObservation { throw WorkflowSteeringAdmissionError.unsupported }
    public func history(observation _: WorkflowSteeringObservation, cursor _: String?) async throws -> WorkflowSteeringHistoryPage {
        throw WorkflowSteeringAdmissionError.unsupported
    }

    public func perform(action _: WorkflowSteeringAction, text _: String?, observation _: WorkflowSteeringObservation) async throws -> WorkflowSteeringAttempt {
        throw WorkflowSteeringAdmissionError.unsupported
    }

    public func attempts(rootID _: String) -> [WorkflowSteeringAttempt] { [] }
    public func isCurrent(_: WorkflowSteeringObservation) -> Bool { false }
}

public extension GlobalValues {
    /// One app-session steering attempt owner.
    @GlobalEntry var workflowSteeringRepository: any WorkflowSteeringRepository = NullWorkflowSteeringRepository()
}
