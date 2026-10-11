//
//  TaskSettledDuration.swift
//  MainWindowFeature
//
//  The one shared guard for a settled task's elapsed display (redesign §1.6/§6.2): a terminal
//  task shows an elapsed time only from its RECORDED `duration_seconds` AND only when its exit was
//  observed. The old code fell back to `TaskInfo.elapsed()` — a now-minus-start computation — for
//  a finished task with no recorded duration, which fabricated an ever-growing duration after
//  settlement. This helper is pure presentation: no clock, no VM timer, no contract or data
//  change; `nil` simply means "show status only" in the header badge, the Summary headline and
//  the Duration tile alike.
//

import Foundation
import MonitorCore

// MARK: - TaskSettledDuration

/// The recorded duration of a terminal task whose exit was observed; `nil` in every other case.
enum TaskSettledDuration {
    /// The one rule shared by `TaskStatusLabel` (header/toolbar badge) and `SummaryPaneModel`'s
    /// hero headline and Duration tile: terminal status + observed `exit_code` + recorded
    /// `duration_seconds`. A missing exit or a missing recorded duration means no elapsed time
    /// is shown anywhere — never a now-minus-start terminal fallback.
    nonisolated static func seconds(for task: TaskInfo) -> TimeInterval? {
        guard task.status.isTerminal, task.exitCode != nil else { return nil }
        return task.durationSeconds
    }
}
