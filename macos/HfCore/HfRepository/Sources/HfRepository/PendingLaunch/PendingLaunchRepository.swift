import Combine
import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - PendingLaunchRepository

/// App-session pending discovery and Stop ownership. Reads are explicit, visibility leased and
/// bounded; there is no automatic namespace polling or launch/cancel retry.
@Mockable
public protocol PendingLaunchRepository: Sendable {
    var snapshot: PendingLaunchSnapshot { get }
    func snapshotPublisher() -> AnyPublisher<PendingLaunchSnapshot, Never>
    func acquireReadLease() -> PendingLaunchReadLease?
    func releaseReadLease(_ lease: PendingLaunchReadLease)
    /// Nil clears selection without releasing inventory interest. Replacement revokes old reads.
    func bindSelection(taskID: String?, lease: PendingLaunchReadLease) -> PendingLaunchSelection?
    func refresh(lease: PendingLaunchReadLease) async
    func check(selection: PendingLaunchSelection) async -> PendingLaunchLookup
    /// Explicit fresh ordinary status followed by runtime/selection-fenced history admission.
    func resolveRecorded(selection: PendingLaunchSelection) async -> PendingLaunchRecordedResult
    func prepareStop(selection: PendingLaunchSelection) async -> PendingLaunchStopPreparation
    func submitStop(confirmation: PendingLaunchStopConfirmation) -> PendingLaunchStopAdmission
    /// Inline runtime notification; revokes all delayed read/adoption work before returning.
    func runtimeChanged()
}

/// Safe default never dispatches and never presents unavailable discovery as empty complete data.
public struct NullPendingLaunchRepository: PendingLaunchRepository {
    public init() {}
    private static let unavailable: PendingLaunchSnapshot = {
        var value = PendingLaunchSnapshot()
        value.inventory.failure = .unavailable
        return value
    }()

    public var snapshot: PendingLaunchSnapshot { Self.unavailable }
    public func snapshotPublisher() -> AnyPublisher<PendingLaunchSnapshot, Never> { Just(snapshot).eraseToAnyPublisher() }
    public func acquireReadLease() -> PendingLaunchReadLease? { nil }
    public func releaseReadLease(_: PendingLaunchReadLease) {}
    public func bindSelection(taskID _: String?, lease _: PendingLaunchReadLease) -> PendingLaunchSelection? { nil }
    public func refresh(lease _: PendingLaunchReadLease) async {}
    public func check(selection: PendingLaunchSelection) async -> PendingLaunchLookup {
        PendingLaunchLookup(selection: selection, value: nil, failure: .unavailable)
    }

    public func resolveRecorded(selection _: PendingLaunchSelection) async -> PendingLaunchRecordedResult { .failed(.unavailable) }
    public func prepareStop(selection _: PendingLaunchSelection) async -> PendingLaunchStopPreparation { .failed(.unavailable) }
    public func submitStop(confirmation _: PendingLaunchStopConfirmation) -> PendingLaunchStopAdmission { .refused(.unavailable) }
    public func runtimeChanged() {}
}

public extension GlobalValues {
    /// Shared discovery and pending Stop owner.
    @GlobalEntry var pendingLaunchRepository: any PendingLaunchRepository = NullPendingLaunchRepository()
}
