import Combine
import Foundation
import MonitorCore
import PbRepository

// MARK: - MenuBarVM + presentation tick (B2)

extension MenuBarVM {

    /// The minute-aligned presentation clock: one shot to the next minute boundary, then repeating
    /// every 60 s. It runs only while the popover content is open — the label has no time-derived
    /// text (its count rides the counts channel) — and is re-aligned on each open; its recompute
    /// refreshes the finished-task ages in the popover content.
    func restartMinuteTick() {
        stopMinuteTick()
        let delay = scheduler.minuteBoundaryDelay(after: scheduler.now())
        let scheduler = scheduler
        let generation = minuteTickGeneration
        minuteTickToken = scheduler.schedule(after: delay) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, minuteTickGeneration == generation else { return }
                minuteRepeatToken = scheduler.scheduleRepeating(every: 60) { [weak self] in
                    Task { @MainActor [weak self] in self?.minuteTicked() }
                }
                minuteTicked()
            }
        }
    }

    func stopMinuteTick() {
        minuteTickGeneration += 1
        minuteTickToken?.cancel()
        minuteTickToken = nil
        minuteRepeatToken?.cancel()
        minuteRepeatToken = nil
    }

    func minuteTicked() {
        guard visibility.menuBarPopoverOpen else { return }
        recompute()
    }
}
