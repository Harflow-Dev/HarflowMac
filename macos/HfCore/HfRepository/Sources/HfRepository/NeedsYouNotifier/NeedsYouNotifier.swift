import Foundation
import Mockable
import SwiftEnvironment

// MARK: - NeedsYouNotifier

/// Turns pending requests and persisted winning answers into individual user notifications.
/// Historical outcomes present in the first qualified observation never notify.
@Mockable
public protocol NeedsYouNotifier: Sendable {
    /// Starts consuming repository events; later calls do nothing.
    func start()
}

// MARK: - NullNeedsYouNotifier

/// Safe pre-registration default that notifies nothing.
public struct NullNeedsYouNotifier: NeedsYouNotifier {
    public init() {}
    public func start() {}
}

public extension GlobalValues {
    /// Global Needs you notifier.
    @GlobalEntry var needsYouNotifier: any NeedsYouNotifier = NullNeedsYouNotifier()
}
