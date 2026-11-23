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
