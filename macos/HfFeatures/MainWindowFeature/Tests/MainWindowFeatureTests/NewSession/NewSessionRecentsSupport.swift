import Combine
import Foundation
import HfRepository
@testable import MainWindowFeature
import Mockable
import MonitorCore

// MARK: - LockedPaths

/// A thread-safe set of paths a test flips while the view model's off-main existence check reads it.
final class LockedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var paths = Set<String>()

    func insert(_ path: String) { lock.withLock { _ = paths.insert(path) } }
    func contains(_ path: String) -> Bool { lock.withLock { paths.contains(path) } }
}

// MARK: - LockedCalls

/// Records the inputs of each off-main existence check.
final class LockedCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []

    func record(_ paths: [String]) { lock.withLock { calls.append(paths) } }
    var all: [[String]] { lock.withLock { calls } }
}

// MARK: - GatedRecentsUseCase

/// A use case whose existence checks suspend until the test answers them, in the order they were requested
/// (a Mockable stub cannot hold its answer).
@MainActor
final class GatedRecentsUseCase: NewSessionUseCase {
    struct Request {
        let paths: [String]
        let continuation: CheckedContinuation<Set<String>, Never>
    }

    let base = MockNewSessionUseCase()
    private(set) var requests: [Request] = []
    var currentTasks: [TaskInfo] = []
    var missingAtStart: Set<String> = []

    init() {
        given(base).qualificationSession().willReturn(QualificationFixture.readySession())
        given(base).backendCatalog.willReturn(.empty)
        given(base).backendCatalogPublisher().willReturn(Empty().eraseToAnyPublisher())
        given(base).modelListing(for: .any).willReturn(ModelListing(state: .available))
    }

    func qualificationSession() -> QualificationSession { base.qualificationSession() }
    func resolvedRepoPath(_ input: String) -> String? { missingAtStart.contains(input) ? nil : input }
    func run(_ request: RunRequest, runtime: QualificationRuntimeToken) async throws -> String { "task" }
    var tasks: [TaskInfo] { currentTasks }
    var agentUsageSnapshot: AgentUsageSnapshot { .init() }
    func agentUsagePublisher() -> AnyPublisher<AgentUsageSnapshot, Never> { Just(.init()).eraseToAnyPublisher() }
    var backendCatalog: BackendCatalog { .empty }
    func backendCatalogPublisher() -> AnyPublisher<BackendCatalog, Never> { Empty().eraseToAnyPublisher() }
    func modelListing(for backend: String) async -> ModelListing { ModelListing(state: .available) }
    func refreshModelListing(for backend: String) async -> ModelListing { ModelListing(state: .available) }

    func existingDirectories(among paths: [String]) async -> Set<String> {
        await withCheckedContinuation { requests.append(Request(paths: paths, continuation: $0)) }
    }

    func answer(_ index: Int, _ existing: Set<String>) { requests[index].continuation.resume(returning: existing) }
}
