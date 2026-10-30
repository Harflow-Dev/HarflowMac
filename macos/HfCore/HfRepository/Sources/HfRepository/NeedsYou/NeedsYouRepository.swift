import Combine
import Foundation
import Mockable
import SwiftEnvironment

// MARK: - NeedsYouRepository

/// Every pending input the Monitor can answer now, across tasks and workflows (including nested
/// nodes and child workflows), whoever started the run. Requests waiting for a live caller, or whose
/// caller cannot be identified, never appear here; they stay in the run's own views.
@Mockable
public protocol NeedsYouRepository: Sendable {
    /// The latest published snapshot.
    var snapshot: NeedsYouSnapshot { get }
    /// Emits the initial snapshot, then only real changes.
    func snapshotPublisher() -> AnyPublisher<NeedsYouSnapshot, Never>
    /// Disposable change events for notifications; deliberately not deduplicated.
    func eventsPublisher() -> AnyPublisher<NeedsYouEvent, Never>
    /// Starts the polling loop once; later calls do nothing.
    func start()
    /// Requests an immediate pass (Retry, becoming visible, after an answer).
    func refresh()
    /// Sends an answer for a question or recovery item.
    func answer(_ item: NeedsYouItem, text: String, additionalAttempts: Int?) async -> NeedsYouAnswerOutcome
    /// Approves or rejects an approval item (`approve` or `reject`).
    func respond(_ item: NeedsYouItem, decision: String) async -> NeedsYouAnswerOutcome
}

// MARK: - NullNeedsYouRepository

/// Safe pre-registration default that never reports anything.
public struct NullNeedsYouRepository: NeedsYouRepository {
    public init() {}
    public var snapshot: NeedsYouSnapshot { NeedsYouSnapshot() }
    public func snapshotPublisher() -> AnyPublisher<NeedsYouSnapshot, Never> { Just(NeedsYouSnapshot()).eraseToAnyPublisher() }
    public func eventsPublisher() -> AnyPublisher<NeedsYouEvent, Never> { Empty().eraseToAnyPublisher() }
    public func start() {}
    public func refresh() {}
    public func answer(_: NeedsYouItem, text _: String, additionalAttempts _: Int?) async -> NeedsYouAnswerOutcome {
        .failed("Needs you is unavailable.")
    }

    public func respond(_: NeedsYouItem, decision _: String) async -> NeedsYouAnswerOutcome { .failed("Needs you is unavailable.") }
}

// MARK: - GlobalValues

public extension GlobalValues {
    /// Global Needs you repository.
    @GlobalEntry var needsYouRepository: any NeedsYouRepository = NullNeedsYouRepository()
}
