import Combine
import Foundation
import Mockable
import SwiftEnvironment

// MARK: - Scheduling

/// The one scheduling seam every production timer in this package goes through: the 1 s FSEvents
/// throttle and the 10 s safety poll (`TaskListRepository`). Tests inject a `MockScheduling` that
/// captures the scheduled closure and invokes it directly, so timing-dependent behaviour is driven
/// without ever sleeping.
@Mockable
public protocol Scheduling: Sendable {

    /// The current time. Routed through the seam so a test can control what "now" means for the
    /// reconcile-interval check without waiting for it.
    func now() -> Date

    /// Schedules `work` to run once, after `interval` seconds. Cancelling the returned token before
    /// it fires prevents `work` from running.
    @discardableResult
    func schedule(after interval: TimeInterval, execute work: @escaping @Sendable () -> Void) -> AnyCancellable

    /// Schedules `work` to run every `interval` seconds, starting after the first interval elapses.
    /// Cancelling the returned token stops further firings.
    @discardableResult
    func scheduleRepeating(every interval: TimeInterval, execute work: @escaping @Sendable () -> Void) -> AnyCancellable
}

// MARK: - NullScheduling

/// A `@GlobalEntry` default that never fires anything — safe to resolve before `Module` registers
/// the real `SystemScheduler`, and never itself calls a `@MainActor` initialiser.
public struct NullScheduling: Scheduling {
    public init() {}
    public func now() -> Date { Date() }
    public func schedule(after _: TimeInterval, execute _: @escaping @Sendable () -> Void) -> AnyCancellable { AnyCancellable {} }
    public func scheduleRepeating(every _: TimeInterval, execute _: @escaping @Sendable () -> Void) -> AnyCancellable { AnyCancellable {} }
}

// MARK: - GlobalValues

public extension GlobalValues {

    /// Global scheduling seam.
    @GlobalEntry var scheduling: any Scheduling = NullScheduling()
}
