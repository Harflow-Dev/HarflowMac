import Combine
import Foundation
import MonitorCore
import PbRepository

// MARK: - Sidebar presentation tick (B2)

/// The sidebar's explicit presentation clock. Until this, the republished-but-equal task array was
/// the only thing refreshing time-derived presentation (Today/Earlier bucketing, finished-task
/// ages); with unchanged polls publishing nothing, a minute-aligned tick takes over that duty —
/// one shot to the next minute boundary, then repeating every 60 s, re-aligned on each show.
/// Running elapsed labels do not use this tick: they already tick via
/// `TimelineView(.periodic(by: 1))` + `TaskInfo.elapsed(now:)` from `startedAt`.
@MainActor
final class SidebarPresentationClock {
    /// Whether anyone can see the Monitor — gates the workflow poll's cadence (paused while the
    /// window is hidden, immediate refresh on show) and the minute-aligned presentation tick.
    let visibility: any MonitorVisibility
    /// The presentation clock seam: the minute-aligned tick runs through it, so tests fire the
    /// tick directly instead of waiting a real minute (never `NullScheduling`, which never fires).
    let scheduler: any Scheduling
    var oneShot: AnyCancellable?
    var repeating: AnyCancellable?
    /// Bumped on every stop, so a one-shot already queued on the main actor can tell it is stale.
    var generation = 0

    init(visibility: any MonitorVisibility, scheduler: any Scheduling) {
        self.visibility = visibility
        self.scheduler = scheduler
    }
}

extension SidebarVM {

    /// (Re)starts the minute-aligned presentation tick. Called on `didAppear()` and on each show —
    /// re-aligning to the next boundary means a window shown at :59 is not left waiting a full
    /// minute for its first tick.
    func restartPresentationTick() {
        stopPresentationTick()
        // The tick runs only while the window is visible; the visibility subscription restarts it
        // on show, and a hidden window needs no time-derived refresh at all.
        guard clock.visibility.mainWindowVisible else { return }
        let scheduler = clock.scheduler
        let delay = scheduler.minuteBoundaryDelay(after: scheduler.now())
        let generation = clock.generation
        clock.oneShot = scheduler.schedule(after: delay) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, clock.generation == generation else { return }
                clock.repeating = scheduler.scheduleRepeating(every: 60) { [weak self] in
                    Task { @MainActor [weak self] in self?.minuteTicked() }
                }
                minuteTicked()
            }
        }
    }

    func stopPresentationTick() {
        clock.generation += 1
        clock.oneShot?.cancel()
        clock.oneShot = nil
        clock.repeating?.cancel()
        clock.repeating = nil
    }

    /// One minute boundary passed: a plain recompute — the background builder reads the current
    /// clock, and the equality-guarded presentation setters suppress anything that did not change.
    func minuteTicked() {
        guard clock.visibility.mainWindowVisible else { return }
        recompute()
    }

    /// Reacts to later visibility changes (the current value is handled by `didAppear()` itself:
    /// tick + recompute): an immediate recompute on show, then a re-aligned tick — the hidden
    /// interval left the ages stale; hiding stops the tick.
    func subscribeToVisibility() {
        clock.visibility
.mainWindowVisiblePublisher()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] visible in
                guard let self else { return }
                if visible {
                    recompute()
                    restartPresentationTick()
                } else {
                    stopPresentationTick()
                }
            }
            .store(in: &cancellables)
    }
}
