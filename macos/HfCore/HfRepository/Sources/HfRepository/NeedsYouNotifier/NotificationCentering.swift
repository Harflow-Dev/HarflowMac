import Foundation
import Mockable
@preconcurrency import UserNotifications

// MARK: - NotificationCentering

/// `UNUserNotificationCenter` behind a protocol, so `InteractionEventNotifier` can be tested without a
/// real app bundle or the notification permission dialog.
@Mockable
public protocol NotificationCentering: Sendable {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func removeDelivered(identifiers: [String])
    func removePending(identifiers: [String])
    func authorizationStatus() async -> NotificationAuthorization
}

// MARK: - SystemNotificationCenter

public struct SystemNotificationCenter: NotificationCentering {
    public init() {}

    public func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: options)
    }

    public func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }

    public func removeDelivered(identifiers: [String]) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    public func removePending(identifiers: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    public func authorizationStatus() async -> NotificationAuthorization {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        // Provisional and ephemeral grants deliver quietly, which still counts as allowed.
        case .authorized, .provisional, .ephemeral: .allowed
        @unknown default: .denied
        }
    }
}
