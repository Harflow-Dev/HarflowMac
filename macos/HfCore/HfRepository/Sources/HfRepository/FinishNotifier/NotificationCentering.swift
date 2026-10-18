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
}
