import Foundation
import Mockable
import SwiftEnvironment

// MARK: - NeedsYouNotifier

/// Turns Needs you events into user notifications. Only requests the Monitor can answer ever
/// reach it, and requests present when a source was first read never notify.
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
