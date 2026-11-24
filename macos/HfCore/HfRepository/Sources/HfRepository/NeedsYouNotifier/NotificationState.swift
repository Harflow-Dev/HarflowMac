import Foundation

// MARK: - NotificationAuthorization

/// The app's notification permission as Settings needs it, independent of `UserNotifications` types.
public enum NotificationAuthorization: Equatable, Sendable {
    case notDetermined, denied, allowed
}

// MARK: - NotificationFeedAvailability

/// Whether the selected runtime serves the durable interaction feed.
public enum NotificationFeedAvailability: Equatable, Sendable {
    /// No page has answered yet.
    case unknown
    case available
    /// The runtime lacks `interaction-events.v1`, so no notification can be posted.
    case unavailable
}
