import Foundation
import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - FinishNotifier

/// User notifications for tasks that finished since the last listing — `AppModel.notifyFinished`
/// (`AppModel.swift:454-472`, = F4-25). The title lookup is passed in by the caller (`TaskListRepository`)
/// rather than read from a shared title repository, so this type never depends back on the type that
/// depends on it.
@Mockable
public protocol FinishNotifier: Sendable {
    func notify(_ finished: [TaskInfo], titleFor: @escaping @Sendable (String) -> String)
}

// MARK: - NullFinishNotifier

public struct NullFinishNotifier: FinishNotifier {
    public init() {}
    public func notify(_: [TaskInfo], titleFor _: @escaping @Sendable (String) -> String) {}
}

// MARK: - GlobalValues

public extension GlobalValues {

    /// Global finish notifier.
    @GlobalEntry var finishNotifier: any FinishNotifier = NullFinishNotifier()
}
