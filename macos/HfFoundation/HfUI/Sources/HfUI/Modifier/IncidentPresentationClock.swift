import Foundation

// MARK: - IncidentPresentationClock

/// One cancellable presentation loop per mount; stale wakeups cannot read or mutate UI state.
@MainActor
final class IncidentPresentationClock {
    private let wake: @MainActor () async throws -> Void
    private let now: @MainActor () -> Date
    private var task: Task<Void, Never>?
    private var mounted = false
    private var generation = UUID()

    var isMounted: Bool { mounted }

    init(wake: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) },
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.wake = wake
        self.now = now
    }

    func mount(tick: @escaping @MainActor (Date, Bool) -> Void) {
        guard !mounted else { return }
        mounted = true
        let token = UUID()
        generation = token
        tick(now(), true)
        guard mounted, generation == token else { return }
        let wake = wake
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await wake() } catch { return }
                guard !Task.isCancelled, let self, mounted, generation == token else { return }
                tick(now(), false)
            }
        }
    }

    func unmount() {
        mounted = false
        generation = UUID()
        task?.cancel()
        task = nil
    }
}
