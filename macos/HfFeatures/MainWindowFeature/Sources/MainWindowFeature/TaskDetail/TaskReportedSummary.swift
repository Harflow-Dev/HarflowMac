//
//  TaskReportedSummary.swift
//  MainWindowFeature
//
//  The one pure projection of a task's reported summary. The Events tab's Result section
//  (`TaskDetailVM.recomputeSummary`) and the Summary feed entry (`TaskDetailTimelineBuilder`) both read
//  it, so they can never disagree about the text.
//

import Foundation
import MonitorCore

// MARK: - TaskReportedSummary

enum TaskReportedSummary {

    /// The summary as the engine reported it. `summary` is a snapshot-only field (nil on a bare
    /// listing), so the freshest snapshot wins over whatever `task` itself resolved to.
    nonisolated static func raw(snapshot: TaskInfo?, task: TaskInfo) -> String? {
        snapshot?.summary ?? task.summary
    }

    /// The displayed text: the workflow builder, managed workflow and malformed-output projections applied
    /// to `raw`, or `raw` itself for an ordinary task.
    nonisolated static func projected(raw: String?, task: TaskInfo, isWorkflowBuilder: Bool) -> String? {
        let projectsWorkflowResult = WorkflowNodePresentation.isManaged(task) || WorkflowNodePresentation.resultError(task) != nil
        return isWorkflowBuilder ? WorkflowBuilderPresentation.summary(raw)
            : projectsWorkflowResult ? WorkflowNodePresentation.summary(raw, task: task) : raw
    }
}
