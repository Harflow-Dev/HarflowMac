import Combine
import Foundation
import Mockable
import SwiftEnvironment

// MARK: - NeedsYouNotifier

/// Turns durable engine interaction events into individual user notifications. Events older than the
/// app's per-state-root floor never notify.
@Mockable
public protocol NeedsYouNotifier: Sendable {
    /// Starts consuming engine interaction events; later calls do nothing.
    func start()
    /// Whether the selected runtime serves the interaction feed, as last observed.
    var feedAvailability: NotificationFeedAvailability { get }
    /// Emits the current availability, then only changes.
    func feedAvailabilityPublisher() -> AnyPublisher<NotificationFeedAvailability, Never>
    /// The notification permission, or nil when the app cannot post notifications (no app bundle).
    func permission() async -> NotificationAuthorization?
}

// MARK: - NullNeedsYouNotifier

/// Safe pre-registration default that notifies nothing.
public struct NullNeedsYouNotifier: NeedsYouNotifier {
    public init() {}
    public func start() {}
    public var feedAvailability: NotificationFeedAvailability { .unknown }
    public func feedAvailabilityPublisher() -> AnyPublisher<NotificationFeedAvailability, Never> {
        Just(.unknown).eraseToAnyPublisher()
    }

    public func permission() async -> NotificationAuthorization? { nil }
}

public extension GlobalValues {
    /// Global Needs you notifier.
    @GlobalEntry var needsYouNotifier: any NeedsYouNotifier = NullNeedsYouNotifier()
}
