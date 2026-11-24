import Combine

// MARK: - NotificationPermissionObserving

/// Optional feature adapter surface for the notification permission row, so legacy feature mocks stay unchanged.
@MainActor
public protocol NotificationPermissionObserving: Sendable {
    /// The notification permission, or nil when the app cannot post notifications.
    func notificationPermission() async -> NotificationAuthorization?
    /// Whether the selected runtime serves the interaction feed, as last observed.
    var feedAvailability: NotificationFeedAvailability { get }
    /// Emits the current availability, then only changes. Delivery may be off the main thread.
    func feedAvailabilityPublisher() -> AnyPublisher<NotificationFeedAvailability, Never>
    /// Emits each time the app becomes active, when the permission may have changed in System Settings.
    func activationPublisher() -> AnyPublisher<Void, Never>
}
