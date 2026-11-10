import Foundation
import MonitorCore

// MARK: - PendingLaunchReadLease

/// Visibility interest. Releasing it immediately revokes its selected-detail reads.
public struct PendingLaunchReadLease: Equatable, Hashable, Sendable {
    public let id: UUID
    init(id: UUID = UUID()) { self.id = id }
}

/// A full-ID selection whose gate is revoked synchronously by any replacement selection.
public struct PendingLaunchSelection: Equatable, Sendable {
    public let id: UUID
    public let taskID: String
    public let lease: PendingLaunchReadLease
    init(taskID: String, lease: PendingLaunchReadLease) {
        self.id = UUID()
        self.taskID = taskID
        self.lease = lease
    }
}

// MARK: - PendingLaunchFailure

/// Read or local admission failures; none establishes absence or settlement.
public enum PendingLaunchFailure: Equatable, Sendable {
    case unavailable, superseded, capacity, busy, unsupported, changed, recorded
    case malformed, requestBudget, deadline, incomplete
    case tool(ToolError)
    case recordedAdmission(PendingRecordedAdmissionFailure)
}

/// Last inventory evidence and independent freshness. An empty incomplete read proves no absence.
public struct PendingLaunchInventory: Equatable, Sendable {
    public var rows: [TaskPendingLaunchItem] = []
    public var isRefreshing = false
    public var isStale = false
    public var completedCheck = false
    public var failure: PendingLaunchFailure?
    public init(rows: [TaskPendingLaunchItem] = [], isRefreshing: Bool = false, isStale: Bool = false,
                completedCheck: Bool = false, failure: PendingLaunchFailure? = nil) {
        self.rows = rows; self.isRefreshing = isRefreshing; self.isStale = isStale
        self.completedCheck = completedCheck; self.failure = failure
    }
}

/// Exact-ID lookup evidence stays independent of inventory and invocation evidence.
public struct PendingLaunchLookup: Equatable, Sendable {
    public let selection: PendingLaunchSelection
    public let value: TaskPendingLaunchLookup?
    public let failure: PendingLaunchFailure?
    public init(selection: PendingLaunchSelection, value: TaskPendingLaunchLookup?, failure: PendingLaunchFailure?) {
        self.selection = selection
        self.value = value
        self.failure = failure
    }
}

/// Explicit ordinary-status admission; cached pending metadata cannot produce a task route.
public enum PendingLaunchRecordedResult: Equatable, Sendable {
    case admitted(TaskInfo)
    case failed(PendingLaunchFailure)
}

/// A single-use confirmation captures the runtime, full identity and launch generation.
public struct PendingLaunchStopConfirmation: Equatable, Sendable {
    public let id: UUID
    public let taskID: String
    public let generation: String
    public let runtime: QualificationRuntimeToken
    let epoch: UUID
}

/// A preparation may discover that an ordinary task record now exists without adopting it.
public enum PendingLaunchStopPreparation: Equatable, Sendable {
    case confirmation(PendingLaunchStopConfirmation)
    case failed(PendingLaunchFailure)
}

/// Submission is owner-owned once admitted and survives navigation and VM teardown.
public enum PendingLaunchStopAdmission: Equatable, Sendable {
    case submitted(UUID)
    case existing(UUID)
    case refused(PendingLaunchFailure)
}

/// Immutable target plus separate preflight and phase-aware invocation evidence.
public struct PendingLaunchStopAttempt: Equatable, Sendable {
    public let id: UUID
    public let confirmation: PendingLaunchStopConfirmation
    public var isExecuting: Bool
    public var preflightFailure: PendingLaunchFailure?
    public var outcome: TaskPendingLaunchStopOutcome?
    /// False: diagnostics and structured reasons are retained verbatim within the reserved bound.
    public var diagnosticsTruncated: Bool = false
}

/// Rendering snapshot. Runtime identity never exposes effective child environment values.
public struct PendingLaunchSnapshot: Equatable, Sendable {
    public var runtimeIdentity: UUID = .init()
    public var currentRuntime: QualificationRuntimeToken?
    public var inventory = PendingLaunchInventory()
    public var lookups: [PendingLaunchLookup] = []
    public var attempts: [PendingLaunchStopAttempt] = []
    public init(runtimeIdentity: UUID = UUID(), currentRuntime: QualificationRuntimeToken? = nil, inventory: PendingLaunchInventory = PendingLaunchInventory(),
                lookups: [PendingLaunchLookup] = [], attempts: [PendingLaunchStopAttempt] = []) {
        self.runtimeIdentity = runtimeIdentity; self.currentRuntime = currentRuntime; self.inventory = inventory
        self.lookups = lookups; self.attempts = attempts
    }
}

// MARK: - PendingRecordedAdmissionFailure

/// A conservative handoff failure. Missing/pruned ancestry never becomes an invented root.
public enum PendingRecordedAdmissionFailure: Error, Equatable, Sendable {
    case ancestorRead(taskID: String, error: ToolError)
    case unqualified(taskID: String)
    case cycle, requestBudget, deadline, responseBudget
}

// MARK: - PendingLaunchAdmissionGate

/// Revocation serializes with pure local history insertion. Never invoke dependencies or publish
/// inside `withCurrent`; callers perform fresh qualification checks outside this gate as well.
public final class PendingLaunchAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    public init() {}
    public var isCurrent: Bool { lock.withLock { valid } }
    public func revoke() { lock.withLock { valid = false } }
    func withCurrent<Value>(_ body: () -> Value) -> Value? {
        lock.withLock { valid ? body() : nil }
    }
}
