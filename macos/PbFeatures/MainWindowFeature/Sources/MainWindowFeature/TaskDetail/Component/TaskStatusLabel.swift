//
//  TaskStatusLabel.swift
//  MainWindowFeature
//
//  The detail header's status badge: the shared `StatusBadge` capsule with a live elapsed time
//  while the task runs (the only clock — no VM timer), and, once settled, the RECORDED duration
//  from `TaskSettledDuration` (terminal + observed exit + recorded `duration_seconds`). A settled
//  task with no observed exit or no recorded duration shows its status only — never a
//  now-minus-start terminal fallback, which fabricated an ever-growing finished duration.
//

import MonitorCore
import PbUI
import SwiftUI

// MARK: - TaskStatusLabel

/// "Running · 01:55" while running (ticks every second); "Done · 21:04" once settled with a
/// recorded duration, with "taken over" when a person took the session over.
struct TaskStatusLabel: View {
    let task: TaskInfo

    var body: some View {
        Group {
        if task.status.isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                StatusBadge(
                    status: task.status,
                    elapsedText: task.elapsed(now: context.date).map(Format.clock),
                    isTakenOver: task.takenOver
                )
            }
        } else {
            StatusBadge(
                status: task.status,
                    elapsedText: (task.status.isTerminal ? TaskSettledDuration.seconds(for: task) : task.elapsed()).map(Format.clock),
                isTakenOver: task.takenOver
            )
        }
        }
        .fixedSize()
    }
}

#if DEBUG
/// Terminal previews carry both `duration_seconds` and `exit_code`, so they show the badge the
/// way a settled run with recorded evidence reads; the missing-evidence variants pin the
/// status-only treatment the shared guard requires.
private func settledTask(status: String, exitCode: Int? = 0, durationSeconds: Double? = 84, takenOver: Bool = false) -> TaskInfo {
    var object: [String: JSONValue] = [
        "task_id": .string("abc12345"), "backend": .string("claude"), "status": .string(status),
        "taken_over": .bool(takenOver)
    ]
    if let exitCode { object["exit_code"] = .number(Double(exitCode)) }
    if let durationSeconds { object["duration_seconds"] = .number(durationSeconds) }
    return TaskInfo(.object(object))!
}

@MainActor
private func statusPreview() -> some View {
    VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing10) {
        TaskStatusLabel(task: TaskDetailViewModelMock.sampleTask())
        TaskStatusLabel(task: TaskDetailViewModelMock.sampleTask(status: "completed"))
        TaskStatusLabel(task: settledTask(status: "completed"))
        TaskStatusLabel(task: settledTask(status: "failed", exitCode: 1))
        TaskStatusLabel(task: settledTask(status: "timed_out", exitCode: 1))
        TaskStatusLabel(task: settledTask(status: "pending", exitCode: nil, durationSeconds: nil))
        TaskStatusLabel(task: settledTask(status: "needs_attention", exitCode: nil, durationSeconds: nil))
        TaskStatusLabel(task: settledTask(status: "settling", exitCode: nil, durationSeconds: nil))
        TaskStatusLabel(task: settledTask(status: "cancelled", takenOver: true))
        TaskStatusLabel(task: settledTask(status: "completed", exitCode: nil))
        TaskStatusLabel(task: settledTask(status: "completed", durationSeconds: nil))
    }
    .padding(PbRadius.Metrics.spacing16)
    .background(Color.windowBG)
}

#Preview("Light") {
    statusPreview().preferredColorScheme(.light)
}

#Preview("Dark") {
    statusPreview().preferredColorScheme(.dark)
}
#endif
