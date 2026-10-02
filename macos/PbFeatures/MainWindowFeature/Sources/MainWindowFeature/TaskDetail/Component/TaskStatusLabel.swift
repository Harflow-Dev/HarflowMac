//
//  TaskStatusLabel.swift
//  MainWindowFeature
//
//  The detail header's status: the status icon, its label, and the elapsed time — live while the
//  task runs. Same elapsed value the old status pill showed (`TaskInfo.elapsed(now:)`).
//

import MonitorCore
import PbUI
import SwiftUI

// MARK: - TaskStatusLabel

/// "● Running · 01:55" while running (ticks every second); "Done · 21:04" once settled, with
/// "· taken over" when a person took the session over.
struct TaskStatusLabel: View {
    let task: TaskInfo

    var body: some View {
        HStack(spacing: 6) {
            if task.status.isRunning { RunningSpinner() } else { StatusIcon(status: task.status) }
            if task.status.isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    label(elapsed: task.elapsed(now: context.date))
                }
            } else {
                label(elapsed: task.elapsed())
            }
        }
        .font(.pb(.secondary, weight: .medium))
        .foregroundStyle(StatusColor.of(task.status))
    }

    private func label(elapsed: TimeInterval?) -> some View {
        HStack(spacing: 4) {
            Text(task.status.label)
            if let elapsed { Text("· \(Format.clock(elapsed))").monospacedDigit() }
            if task.takenOver { Text("· taken over") }
        }
    }
}

#if DEBUG
@MainActor
private func statusPreview() -> some View {
    VStack(alignment: .leading, spacing: 10) {
        TaskStatusLabel(task: TaskDetailViewModelMock.sampleTask())
        TaskStatusLabel(task: TaskDetailViewModelMock.sampleTask(status: "completed"))
        TaskStatusLabel(task: TaskDetailViewModelMock.sampleTask(status: "failed"))
        TaskStatusLabel(task: TaskDetailViewModelMock.sampleTask(status: "cancelled", takenOver: true))
    }
    .padding()
    .background(Color.windowBG)
}

#Preview("Light") {
    statusPreview().preferredColorScheme(.light)
}

#Preview("Dark") {
    statusPreview().preferredColorScheme(.dark)
}
#endif
