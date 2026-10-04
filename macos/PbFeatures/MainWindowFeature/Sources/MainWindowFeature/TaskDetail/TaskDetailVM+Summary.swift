//
//  TaskDetailVM+Summary.swift
//  MainWindowFeature
//
//  The Summary tab (piece 2/3 of the Monitor architecture plan): git is gone; everything here comes
//  from the task's own reported fields and its raw event stream. No poll, no generation guard — the
//  git flow (`TaskDetailVM+Changes.swift`, removed) needed both because it awaited a network-ish
//  process each time; this is a pure, synchronous rebuild from data the VM already holds.
//
//  Monitor piece 7: the final answer, refusals and usage stay the CURRENT member's own (Design
//  point 6); "Files the agent edited" is built across every member's own events
//  (`SummaryPaneModel.build(task:summary:memberEventsOldestFirst:memberAvailabilities:)`), pairing
//  each member's calls/results independently (Review round 1, item 1).
//
//  "What was enforced" no longer lives here (Summary-tab item 15): the Inspector's own model
//  carries the enforcement lines now — see `TaskDetailVM+Inspector.swift`.
//

import Foundation
import MonitorCore

extension TaskDetailVM {

    func recomputeSummary(task: TaskInfo) {
        // `summary` is a snapshot-only field (nil on a bare listing), so the freshest snapshot
        // wins over whatever `task` itself resolved to — the same precedence the git-backed
        // Changes pane used before it.
        let rawSummary = useCase.snapshot(currentTaskID)?.summary ?? task.summary
        let summary = isWorkflowBuilder ? WorkflowBuilderPresentation.summary(rawSummary)
        : WorkflowNodePresentation.isManaged(task) ? WorkflowNodePresentation.summary(rawSummary) : rawSummary
        let members = conversationMembers
        let memberEvents = members.map { eventsByMember[$0.taskID] ?? [] }
        let memberAvailabilities = members.map { eventsAvailabilityByMember[$0.taskID] ?? .loading }
        summaryModel = SummaryPaneModel.build(
            task: task, summary: summary, memberEventsOldestFirst: memberEvents, memberAvailabilities: memberAvailabilities
        )
    }
}
