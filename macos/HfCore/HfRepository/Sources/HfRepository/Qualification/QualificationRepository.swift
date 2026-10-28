import Foundation
import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - QualificationRequest

/// Immutable public command input. Workflow names remain positional arguments.
public enum QualificationRequest: Equatable, Sendable {
    case task(options: [String])
    case workflow(name: String, options: [String])
    case harness(backend: String)
}

/// Captures actual selected tooling, including its immutable generation executable path.
public struct QualificationRuntimeToken: Equatable, Sendable {
    /// Absolute executable path selected for this evidence.
    public let executable: String
    /// Effective child environment of the selected client.
    public let environment: [String: String]
    /// Selected runtime compatibility and state-root binding.
    public let context: RuntimeCompatibilityContext

    /// Captures the actual selected client without discovering another runtime.
    public init(client: CtlClient) {
        self.executable = client.executable
        self.environment = client.environment
        self.context = client.compatibilityContext
    }
}

/// Transport seam separates selected-runtime binding from each consumer's UI lifecycle.
@Mockable
public protocol QualificationRepository: Sendable {
    /// Returns the actual current selected-runtime binding or its readiness refusal.
    func runtimeToken() throws -> QualificationRuntimeToken
    /// Reads cached public requirements while preserving the selected runtime.
    func discover(_ request: QualificationRequest, runtime: QualificationRuntimeToken) async throws -> BackendQualificationPlan
    /// Runs only explicitly requested feature checks for the selected runtime.
    func check(backend: String, features: [String], runtime: QualificationRuntimeToken) async throws
}

/// Public-command adapter that revalidates selected tooling around suspended work.
public struct QualificationRepositoryImpl: QualificationRepository {
    private let tooling: any ToolEnvironmentRepository
    private let recovery: any StateRecoveryRepository

    /// Creates an adapter using shared selected tooling and state recovery.
    public init(tooling: any ToolEnvironmentRepository, recovery: any StateRecoveryRepository) {
        self.tooling = tooling
        self.recovery = recovery
    }

    /// Returns the actual current selected-runtime binding or its readiness refusal.
    public func runtimeToken() throws -> QualificationRuntimeToken {
        QualificationRuntimeToken(client: try tooling.ctl().get())
    }

    private func client(for token: QualificationRuntimeToken) throws -> CtlClient {
        try token.boundClient(tooling: tooling)
    }

    /// Reads cached public requirements while preserving the selected runtime.
    public func discover(_ request: QualificationRequest, runtime: QualificationRuntimeToken) async throws -> BackendQualificationPlan {
        let client = try client(for: runtime)
        let result: Result<BackendQualificationPlan, ToolError> = switch request {
        case .harness(let backend): await client.harnessQualificationPlan(backend: backend)
        case .task(let options): await client.taskQualificationPlan(options: options)
        case .workflow(let name, let options): await client.workflowQualificationPlan(name: name, options: options)
        }
        if case .failure(let error) = result { recovery.report(error) }
        let plan = try result.get()
        _ = try self.client(for: runtime)
        return plan
    }

    /// Runs only explicitly requested feature checks for the selected runtime.
    public func check(backend: String, features: [String], runtime: QualificationRuntimeToken) async throws {
        let client = try client(for: runtime)
        let result = await client.qualify(backend: backend, features: features)
        if case .failure(let error) = result { recovery.report(error) }
        _ = try result.get() // Exit-one feature failures are data; fresh discovery is authoritative.
        _ = try self.client(for: runtime)
    }
}

/// Identity and request consistency failures detected by the lifecycle.
public enum QualificationSessionError: Error, Sendable {
    /// The selected engine runtime changed during the attempt.
    case runtimeChanged
    /// Candidate requirements or binary identity changed during the attempt.
    case evidenceChanged
    /// A required candidate has no complete binary identity.
    case missingIdentity
    /// The response omitted the origin required by the requested operation.
    case missingRequirements
}

public extension QualificationRuntimeToken {
    /// Uses this immutable selected runtime and checks its selection again after each handshake.
    func boundClient(tooling: any ToolEnvironmentRepository) throws -> CtlClient {
        var client = try tooling.ctl().get()
        guard QualificationRuntimeToken(client: client) == self else { throw QualificationSessionError.runtimeChanged }
        let originalCheck = client.operationIsCurrent
        let token = self
        client.operationIsCurrent = {
            guard originalCheck(), let current = try? tooling.ctl().get() else { return false }
            return QualificationRuntimeToken(client: current) == token
        }
        return client
    }
}

// MARK: - QualificationFailure

/// Structured refusal retained for presentation without matching localized or diagnostic strings.
public enum QualificationFailure: Equatable, Sendable {
    /// The original structured public tool failure.
    case tool(ToolError)
    /// The selected engine runtime changed during the attempt.
    case runtimeChanged
    /// Candidate requirements or binary identity changed during the attempt.
    case evidenceChanged
    /// A required candidate has no complete binary identity.
    case missingIdentity
    /// The response omitted the origin required by the requested operation.
    case missingRequirements
    /// A bounded diagnostic for an unclassified error.
    case other(String)

    /// Preserves known error classifications and bounds unknown diagnostics.
    public init(error: any Error) {
        if let error = error as? ToolError {
            self = .tool(error)
        } else if let error = error as? QualificationSessionError {
            switch error {
            case .runtimeChanged: self = .runtimeChanged
            case .evidenceChanged: self = .evidenceChanged
            case .missingIdentity: self = .missingIdentity
            case .missingRequirements: self = .missingRequirements
            }
        } else {
            self = .other(String(String(describing: error).prefix(1000)))
        }
    }

    /// Bounded display detail; callers can choose state-specific controls from the structured case.
    public var displayMessage: String {
        let message: String = switch self {
        case .tool(let error): error.message
        case .runtimeChanged: "The selected Harflow runtime changed. Check the harness again."
        case .evidenceChanged: "The harness binary or required features changed. Check the harness again."
        case .missingIdentity: "The engine could not identify a required harness binary."
        case .missingRequirements: "The engine returned no complete qualification requirements for this request."
        case .other(let message): message
        }
        return String(message.prefix(1000))
    }
}

// MARK: - QualificationSession

/// Per-consumer lifecycle. Cancel invalidates adoption, without claiming engine termination.
/// Actor reentrancy is guarded after every suspension; a prior attempt cannot restore readiness.
public actor QualificationSession {
    /// Complete immutable state for observation and feature presentation.
    public struct Snapshot: Equatable, Sendable {
        /// Lifecycle states retained independently of qualification feature outcomes.
        public enum Phase: Equatable, Sendable {
            /// No discovery or explicit check has started.
            case idle
            /// Cached public requirements are being read.
            case discovering
            /// An explicit qualification attempt is in progress.
            case checking
            /// Discovery completed; the retained plan determines readiness.
            case settled
            /// The UI stopped adopting this attempt; engine completion is unknown.
            case cancelled
            /// Input changes discarded the previous request and its evidence.
            case invalidated
            /// A required check failed.
            case failed(QualificationFailure)
        }

        /// Attempt generation used to reject superseded work.
        public let generation: UInt64
        /// Current lifecycle phase, including structured failures.
        public let phase: Phase
        /// Actual runtime binding for a settled plan and its subsequent commands.
        public let runtime: QualificationRuntimeToken?
        /// Latest retained discovery; only settled readiness authorizes qualification.
        public let plan: BackendQualificationPlan?
        /// Binary identity currently being checked, or nil between checks.
        public let checkingIdentity: BackendQualificationIdentity?
        /// Backend identifiers whose explicit checks have finished in this attempt.
        public let completedBackends: [String]
        /// Whether the current evidence satisfies all qualification requirements.
        public var isReady: Bool { phase == .settled && plan?.isReady == true }
    }

    private let repository: any QualificationRepository
    private var generation: UInt64 = 0
    private var request: QualificationRequest?
    private var runtime: QualificationRuntimeToken?
    private var plan: BackendQualificationPlan?
    private var phase: Snapshot.Phase = .idle { didSet { publish() } }
    private var checkingIdentity: BackendQualificationIdentity?
    private var completedBackends: [String] = []
    private var observers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var lastPublished: Snapshot?

    /// Buffered newest-only delivery; complete equality suppresses unchanged rendering state.
    public func snapshots() -> AsyncStream<Snapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(snapshot)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func publish() {
        let value = snapshot
        guard value != lastPublished else { return }
        lastPublished = value
        for observer in observers.values { observer.yield(value) }
    }

    /// Creates an idle lifecycle without starting discovery or checks.
    public init(repository: any QualificationRepository) { self.repository = repository }
    /// Current complete lifecycle value without initiating work.
    public var snapshot: Snapshot {
        Snapshot(generation: generation, phase: phase, runtime: runtime, plan: plan,
                 checkingIdentity: checkingIdentity, completedBackends: completedBackends)
    }

    /// Invalidates result adoption without claiming that the engine process stopped.
    public func cancel() {
        generation &+= 1
        checkingIdentity = nil
        phase = .cancelled
        // Keep failed details for rendering; isReady remains false.
    }

    /// Discards the request and evidence after input or selection changes.
    public func invalidate() {
        generation &+= 1
        request = nil
        runtime = nil
        plan = nil
        checkingIdentity = nil
        completedBackends = []
        phase = .invalidated
    }

    /// Mount/input changes call cached-only discovery; never initiates a provider check.
    /// Reads cached public requirements while preserving the selected runtime.
    @discardableResult
    public func discover(_ request: QualificationRequest) async -> Snapshot {
        generation &+= 1
        let attempt = generation
        self.request = request
        plan = nil
        checkingIdentity = nil
        completedBackends = []
        phase = .discovering
        do {
            let runtime = try repository.runtimeToken()
            self.runtime = runtime
            let plan = try await repository.discover(request, runtime: runtime)
            try Self.validateOrigins(plan, request: request)
            guard attempt == generation, !Task.isCancelled else { return snapshot }
            guard try repository.runtimeToken() == runtime else { throw QualificationSessionError.runtimeChanged }
            self.plan = plan
            phase = .settled
        } catch {
            guard attempt == generation, !Task.isCancelled else { return snapshot }
            checkingIdentity = nil
            phase = .failed(QualificationFailure(error: error))
        }
        return snapshot
    }

    /// Explicit check/retry only. Requirements are rediscovered both before and after probes.
    /// Runs only explicitly requested feature checks for the selected runtime.
    @discardableResult
    public func check() async -> Snapshot {
        guard let request else { return snapshot }
        generation &+= 1
        let attempt = generation
        checkingIdentity = nil
        completedBackends = []
        phase = .checking
        do {
            let runtime = try repository.runtimeToken()
            self.runtime = runtime
            let before = try await repository.discover(request, runtime: runtime)
            try Self.validateOrigins(before, request: request)
            guard attempt == generation, !Task.isCancelled else { return snapshot }
            guard try repository.runtimeToken() == runtime else { throw QualificationSessionError.runtimeChanged }
            let groups = try Self.checkGroups(before)
            plan = before
            publish()
            guard try await runChecks(groups, runtime: runtime, attempt: attempt) else { return snapshot }
            checkingIdentity = nil
            let after = try await repository.discover(request, runtime: runtime)
            try Self.validateOrigins(after, request: request)
            guard attempt == generation, !Task.isCancelled else { return snapshot }
            guard try repository.runtimeToken() == runtime else { throw QualificationSessionError.runtimeChanged }
            guard Self.sameRequirements(before, after) else { throw QualificationSessionError.evidenceChanged }
            plan = after
            phase = .settled
        } catch {
            guard attempt == generation, !Task.isCancelled else { return snapshot }
            checkingIdentity = nil
            phase = .failed(QualificationFailure(error: error))
        }
        return snapshot
    }

    private static func validateOrigins(_ plan: BackendQualificationPlan, request: QualificationRequest) throws {
        let valid: Bool = switch request {
        case .task:
            plan.requirements.count == 1 && plan.requirements.first?.id == "task"
        case .workflow:
            plan.requirements.contains { $0.id.hasSuffix("/orchestrator/0") }
        case .harness(let backend):
            plan.requirements.count == 1 && plan.requirements.first?.id == "settings/" + backend
        }
        guard valid else { throw QualificationSessionError.missingRequirements }
    }

    private func runChecks(_ groups: [String: (BackendQualificationIdentity, Set<String>)],
                           runtime: QualificationRuntimeToken, attempt: UInt64) async throws -> Bool {
        for backend in groups.keys.sorted() {
            guard attempt == generation, !Task.isCancelled else { return false }
            checkingIdentity = groups[backend]!.0
            publish()
            try await repository.check(backend: backend, features: groups[backend]!.1.sorted(), runtime: runtime)
            guard attempt == generation, !Task.isCancelled else { return false }
            guard try repository.runtimeToken() == runtime else { throw QualificationSessionError.runtimeChanged }
            completedBackends.append(backend)
            checkingIdentity = nil
            publish()
        }
        return true
    }

    // A discovery racing across binary identities cannot certify the immutable request.
    private static func checkGroups(_ plan: BackendQualificationPlan) throws -> [String: (BackendQualificationIdentity, Set<String>)] {
        var groups: [String: (BackendQualificationIdentity, Set<String>)] = [:]
        for requirement in plan.requirements where !requirement.requiredFeatures.isEmpty {
            guard let identity = requirement.identity, identity.backend == requirement.backend else {
                throw QualificationSessionError.missingIdentity
            }
            if let previous = groups[requirement.backend], previous.0 != identity {
                throw QualificationSessionError.evidenceChanged
            }
            groups[requirement.backend] = (identity, (groups[requirement.backend]?.1 ?? []).union(requirement.requiredFeatures))
        }
        return groups
    }

    private static func sameRequirements(_ lhs: BackendQualificationPlan, _ rhs: BackendQualificationPlan) -> Bool {
        guard lhs.requirements.count == rhs.requirements.count else { return false }
        let right = Dictionary(uniqueKeysWithValues: rhs.requirements.map { ($0.id, $0) })
        return lhs.requirements.allSatisfy { row in
            guard let other = right[row.id] else { return false }
            return row.backend == other.backend && row.identity == other.identity && Set(row.requiredFeatures) == Set(other.requiredFeatures)
        }
    }
}

// MARK: - NullQualificationRepository

/// Missing configuration never implies qualification readiness.
public struct NullQualificationRepository: QualificationRepository {
    /// Creates an unavailable default implementation.
    public init() {}
    /// Returns the actual current selected-runtime binding or its readiness refusal.
    public func runtimeToken() throws -> QualificationRuntimeToken { throw unavailable }
    /// Reads cached public requirements while preserving the selected runtime.
    public func discover(_: QualificationRequest, runtime _: QualificationRuntimeToken) async throws -> BackendQualificationPlan { throw unavailable }
    /// Runs only explicitly requested feature checks for the selected runtime.
    public func check(backend _: String, features _: [String], runtime _: QualificationRuntimeToken) async throws { throw unavailable }
    private var unavailable: ToolError {
        .unsupportedCommand(tool: "harflow-ctl", command: "qualification", detail: "Qualification unavailable")
    }
}

public extension GlobalValues {
    /// Cached qualification discovery and explicit checks for a selected engine runtime.
    @GlobalEntry var qualificationRepository: any QualificationRepository = NullQualificationRepository()
}
