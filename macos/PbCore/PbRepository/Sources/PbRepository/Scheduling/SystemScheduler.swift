import Combine
import Foundation

// MARK: - SystemScheduler

/// Production `Scheduling`: real timers, today's exact intervals. Both `schedule(after:execute:)`
/// and `scheduleRepeating(every:execute:)` run on a dedicated background `DispatchQueue` via
/// `DispatchSourceTimer`, deliberately **not** `RunLoop.main`/`Timer` (what `AppModel` used) or
/// `DispatchQueue.main.asyncAfter`: a `DispatchSourceTimer` fires from the thread pool regardless of
/// whether anything is pumping the main run loop, which a plain CLI process (including `swift test`)
/// is not guaranteed to do, and repositories are `nonisolated` now — nothing here needs the main
/// thread. Every repository routes its published state through `@Subjected`, which is safe to write
/// from any thread.
public final class SystemScheduler: Scheduling, @unchecked Sendable {

    private let queue = DispatchQueue(label: "dev.polybridge.monitor.scheduler")

    public init() {}

    public func now() -> Date { Date() }

    @discardableResult
    public func schedule(after interval: TimeInterval, execute work: @escaping @Sendable () -> Void) -> AnyCancellable {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + interval, execute: item)
        return AnyCancellable { item.cancel() }
    }

    @discardableResult
    public func scheduleRepeating(every interval: TimeInterval, execute work: @escaping @Sendable () -> Void) -> AnyCancellable {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: work)
        timer.resume()
        return AnyCancellable { timer.cancel() }
    }
}
