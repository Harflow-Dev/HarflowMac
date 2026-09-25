//
//  TaskDetailVM+Timeline.swift
//  MainWindowFeature
//
//  The Timeline tab, the Prompt tab's text, and Raw Events. Unknown events never enter
//  `latestItems` (`Timeline.items(from:)` already drops `.unknown` — MS-DETAIL-6), so they can only
//  ever appear in `rawEvents` (all decoded events, `TaskDetailVM.didAppear`/`itemsPublisher` sink).
//

import Foundation
import MonitorCore

extension TaskDetailVM {
    
    /// Rebuilds the Timeline tab's model: step count, the raw items, whether the task is live (for a
    /// running tool's spinner), and the sub-task strip (only when the task has children).
    func recomputeTimeline(task: TaskInfo) {
        let children = useCase.children(of: taskID)
        let start = task.startedAt ?? latestItems.first?.at
        let live = task.status.isRunning
        let subTaskStrip: SubTaskStripModel? = children.isEmpty ? nil : SubTaskStripModel(
            children: children.map { SubTaskEntry(task: $0, title: useCase.title($0.taskID)) },
            start: start,
            onSelectTask: { [weak self] id in self?.didTapTask(id) }
        )
        timelineModel = TimelinePaneModel(
            stepCountText: "\(latestItems.count) steps",
            items: latestItems,
            start: start,
            live: live,
            emptyText: latestItems.isEmpty
            ? (task.status.isRunning ? "Waiting for the first event…" : "This task's event log is empty or was not found.")
            : nil,
            subTaskStrip: subTaskStrip
        )
        promptText = useCase.prompt(for: taskID)
        ?? "The prompt is recorded in the task's event log, which has not been read yet (or does not exist)."
    }
}
