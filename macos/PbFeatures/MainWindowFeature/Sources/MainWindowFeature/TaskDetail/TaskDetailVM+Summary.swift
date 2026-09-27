//
//  TaskDetailVM+Summary.swift
//  MainWindowFeature
//
//  The Summary tab (piece 2/3 of the Monitor architecture plan): git is gone; everything here comes
//  from the task's own reported fields and its raw event stream. No poll, no generation guard — the
//  git flow (`TaskDetailVM+Changes.swift`, removed) needed both because it awaited a network-ish
//  process each time; this is a pure, synchronous rebuild from data the VM already holds.
//

import Foundation
import MonitorCore

extension TaskDetailVM {

    func recomputeSummary(task: TaskInfo) {
        // `summary` is a snapshot-only field (nil on a bare listing), so the freshest snapshot
        // wins over whatever `task` itself resolved to — the same precedence the git-backed
        // Changes pane used before it.
        let summary = useCase.snapshot(taskID)?.summary ?? task.summary
        summaryModel = SummaryPaneModel.build(task: task, summary: summary, events: rawEvents, eventsAvailability: latestEventsAvailability)
    }
}
