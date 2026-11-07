//
//  TaskDetailVM+Summary.swift
//  MainWindowFeature
//
//  The summary model (piece 2/3 of the Monitor architecture plan): git is gone; everything here comes
//  from the task's own reported fields and the observed activity summaries. No poll, no generation guard — the
//  git flow (`TaskDetailVM+Changes.swift`, removed) needed both because it awaited a network-ish
//  process each time; this is a pure, synchronous rebuild from data the VM already holds.
//
//  Monitor piece 7: the final answer, refusals and usage stay the CURRENT member's own (Design
//  point 6); "Files edited" is merged across every member's own
//  observed summary projection (`observationFrames[_].summary`), already paired per member; the
//  base model is built with no raw events.
//
//  "What was enforced" no longer lives here (item 15): the Inspector's own model
//  carries the enforcement lines now — see `TaskDetailVM+Inspector.swift`.
//

import Foundation
import HfRepository
import MonitorCore

extension TaskDetailVM {

    func recomputeSummary(task: TaskInfo) {
        recomputeArtifactMembers()
        // `summary` is a snapshot-only field (nil on a bare listing), so the freshest snapshot
        // wins over whatever `task` itself resolved to — the same precedence the git-backed
        // Changes pane used before it.
        let rawSummary = useCase.snapshot(currentTaskID)?.summary ?? task.summary
        let projectsWorkflowResult = WorkflowNodePresentation.isManaged(task) || WorkflowNodePresentation.resultError(task) != nil
        let summary = isWorkflowBuilder ? WorkflowBuilderPresentation.summary(rawSummary)
            : projectsWorkflowResult ? WorkflowNodePresentation.summary(rawSummary, task: task) : rawSummary
        let members = conversationMembers
        let summaries = members.map { observationFrames[$0.taskID]?.summary ?? ObservedActivitySummary() }
        let base = SummaryPaneModel.build(task: task, summary: summary, memberEventsOldestFirst: [],
            memberAvailabilities: summaries.map { $0.state == .observed ? .available : $0.state == .loading ? .loading : .unavailable })
        var order: [String] = []
        var latest: [String: EditedFileStatus] = [:]
        let prefix = task.repoPath.hasSuffix("/") ? task.repoPath : task.repoPath + "/"
        for projection in summaries {
            for file in projection.files {
                let path = !task.repoPath.isEmpty && file.path.hasPrefix(prefix) ? String(file.path.dropFirst(prefix.count)) : file.path
                if latest[path] == nil { order.append(path) }
                latest[path] = file.status
            }
        }

        let partialConversation = conversationLoading || conversationHasMore || conversationHistoryIncomplete || conversationError != nil
        let unavailable = summaries.contains { $0.state == .unavailable || $0.state == .limited }
        let filesQualified = !partialConversation && !summaries.isEmpty && summaries.allSatisfy { $0.state == .observed }
        let availability: EventAvailability = unavailable ? .unavailable : filesQualified ? .available : .loading
        let additional = filesQualified ? summaries.reduce(0) { $0 + max(0, ($1.totalFiles ?? 0) - $1.files.count) } : 0
        let note = unavailable ? "File accounting is unavailable because some captured history could not be qualified."
            : !filesQualified ? "Conversation history is incomplete; file accounting is not qualified."
            : additional > 0 ? "This bounded view shows only the admitted file entries; additional qualified entries are not displayed." : base.editedFilesNote
        summaryModel = SummaryPaneModel(
            hero: base.hero, finalAnswer: base.finalAnswer, finalAnswerPlaceholder: base.finalAnswerPlaceholder,
            refusalLines: base.refusalLines, editedFilesAvailability: availability,
            editedFiles: filesQualified ? order.map { EditedFile(path: $0, status: latest[$0] ?? .unconfirmed) } : [],
            editedFilesNote: note,
            numTurns: base.numTurns,
            inputTokens: base.inputTokens, outputTokens: base.outputTokens, costUSD: base.costUSD,
            additionalFileCount: additional,
            onLoadMoreFiles: nil
        )
    }
}
