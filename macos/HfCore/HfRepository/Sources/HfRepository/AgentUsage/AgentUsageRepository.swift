import Combine
import Foundation
import HfUtilities
import Mockable
import SwiftEnvironment

// MARK: - AgentUsageIdentity

/// An agent and its exact submitted model identifier; nil represents the harness default.
public struct AgentUsageIdentity: Codable, Hashable, Sendable {
    public let backend: String
    public let model: String?

    public init(backend: String, model: String?) {
        self.backend = backend
        self.model = model.flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: - AgentUsageSnapshot

/// Lifetime counts of acknowledged app submissions, shared by all agent pickers.
public struct AgentUsageSnapshot: Codable, Equatable, Sendable {
    public let counts: [AgentUsageIdentity: UInt64]
    private let backendTotals: [String: UInt64]
    private enum CodingKeys: String, CodingKey { case counts }

    public init(counts: [AgentUsageIdentity: UInt64] = [:]) {
        self.counts = counts
        var totals: [String: UInt64] = [:]
        for (identity, count) in counts {
            let sum = (totals[identity.backend] ?? 0).addingReportingOverflow(count)
            totals[identity.backend] = sum.overflow ? .max : sum.partialValue
        }
        self.backendTotals = totals
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(counts: try container.decode([AgentUsageIdentity: UInt64].self, forKey: .counts))
    }

    /// Orders distinct available backend identities by usage, then binary identity.
    public func rankedBackends(_ backends: [String]) -> [String] {
        Set(backends).sorted {
            let lhs = backendTotals[$0] ?? 0, rhs = backendTotals[$1] ?? 0
            return lhs == rhs ? $0.utf8.lexicographicallyPrecedes($1.utf8) : lhs > rhs
        }
    }

    /// Orders exact model values without changing labels or introducing unavailable options.
    public func rankedModels(_ models: [ModelOption], backend: String) -> [ModelOption] {
        var seen = Set<String>()
        return models.filter { !$0.value.isEmpty && seen.insert($0.value).inserted }.sorted {
            let lhs = counts[AgentUsageIdentity(backend: backend, model: $0.value)] ?? 0
            let rhs = counts[AgentUsageIdentity(backend: backend, model: $1.value)] ?? 0
            return lhs == rhs ? $0.value.utf8.lexicographicallyPrecedes($1.value.utf8) : lhs > rhs
        }
    }
}

// MARK: - AgentUsageRepository

/// Persists a submission once per namespaced acknowledgement identifier.
@Mockable
public protocol AgentUsageRepository: Sendable {
    var snapshot: AgentUsageSnapshot { get }
    func snapshotPublisher() -> AnyPublisher<AgentUsageSnapshot, Never>
    func record(_ identity: AgentUsageIdentity, acknowledgementID: String) async
}

/// Empty repository used before module registration.
public struct NullAgentUsageRepository: AgentUsageRepository {
    public init() {}
    public var snapshot: AgentUsageSnapshot { .init() }
    public func snapshotPublisher() -> AnyPublisher<AgentUsageSnapshot, Never> { Just(.init()).eraseToAnyPublisher() }
    public func record(_: AgentUsageIdentity, acknowledgementID _: String) async {}
}

public extension GlobalValues {
    /// Shared app submission history.
    @GlobalEntry var agentUsageRepository: any AgentUsageRepository = NullAgentUsageRepository()
}

// MARK: - AgentUsageRepositoryImpl

/// Serializes count and acknowledgement persistence as one defaults value.
public final class AgentUsageRepositoryImpl: AgentUsageRepository, @unchecked Sendable {
    public static let storageKey = "agentUsage.v1"
    @Subjected private var value: AgentUsageSnapshot
    private let storage: Storage

    public init(defaults: UserDefaults = .standard) {
        let persistence = DefaultsPersistence(defaults: defaults)
        let initial = persistence.load().flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        _value = Subjected(wrappedValue: initial.snapshot)
        self.storage = Storage(persistence: persistence, state: initial)
    }

    public var snapshot: AgentUsageSnapshot { value }
    public func snapshotPublisher() -> AnyPublisher<AgentUsageSnapshot, Never> { $value.removeDuplicates().eraseToAnyPublisher() }
    public func record(_ identity: AgentUsageIdentity, acknowledgementID: String) async {
        guard !identity.backend.isEmpty, !acknowledgementID.isEmpty else { return }
        await storage.record(identity, id: acknowledgementID) { [self] snapshot in value = snapshot }
    }

    private struct State: Codable, Sendable {
        var snapshot = AgentUsageSnapshot()
        var acknowledgements: Set<String> = []
    }

    /// UserDefaults supports concurrent reads and writes. This immutable boundary exposes only
    /// the one Data value; Storage separately serializes the compound count/acknowledgement update.
    private struct DefaultsPersistence: @unchecked Sendable {
        private let defaults: UserDefaults

        init(defaults: UserDefaults) { self.defaults = defaults }
        func load() -> Data? { defaults.data(forKey: AgentUsageRepositoryImpl.storageKey) }
        func save(_ data: Data) { defaults.set(data, forKey: AgentUsageRepositoryImpl.storageKey) }
    }

    private actor Storage {
        let persistence: DefaultsPersistence
        var state: State
        init(persistence: DefaultsPersistence, state: State) { self.persistence = persistence; self.state = state }
        func record(_ identity: AgentUsageIdentity, id: String, publish: @Sendable (AgentUsageSnapshot) -> Void) {
            guard state.acknowledgements.insert(id).inserted else { return }
            let count = state.snapshot.counts[identity] ?? 0
            var counts = state.snapshot.counts
            counts[identity] = count == .max ? .max : count + 1
            state.snapshot = AgentUsageSnapshot(counts: counts)
            guard let data = try? JSONEncoder().encode(state) else { return }
            persistence.save(data)
            publish(state.snapshot)
        }
    }
}
