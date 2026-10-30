import Foundation
import Mockable
@preconcurrency import UserNotifications

// MARK: - NotificationCentering

/// `UNUserNotificationCenter` behind a protocol, so `FinishNotifierImpl` can be tested without a
/// real app bundle or the notification permission dialog.
@Mockable
public protocol NotificationCentering: Sendable {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    /// Registers categories; a category's placeholder replaces the body when previews are hidden.
    func registerCategory(_ category: UNNotificationCategory) async
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

    public func registerCategory(_ category: UNNotificationCategory) async {
        let center = UNUserNotificationCenter.current()
        var categories = await center.notificationCategories()
        categories = categories.filter { $0.identifier != category.identifier }
        categories.insert(category)
        center.setNotificationCategories(categories)
    }

    public func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
