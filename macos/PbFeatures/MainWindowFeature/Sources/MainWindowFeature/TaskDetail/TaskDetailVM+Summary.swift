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
        let projectsWorkflowResult = WorkflowNodePresentation.isManaged(task) || WorkflowNodePresentation.resultError(task) != nil
        let summary = isWorkflowBuilder ? WorkflowBuilderPresentation.summary(rawSummary)
            : projectsWorkflowResult ? WorkflowNodePresentation.summary(rawSummary, task: task) : rawSummary
        let members = conversationMembers
        let summaries = members.map { useCase.eventSummary(for: $0.taskID) }
        let base = SummaryPaneModel.build(task: task, summary: summary, memberEventsOldestFirst: [], memberAvailabilities: summaries.map(\.availability))
        var order: [String] = []
        var latest: [String: EditedFileStatus] = [:]
        let prefix = task.repoPath.hasSuffix("/") ? task.repoPath : task.repoPath + "/"
        for projection in summaries {
            var memberVersions: [String: Int] = [:]
            for file in projection.files {
                let path = !task.repoPath.isEmpty && file.path.hasPrefix(prefix) ? String(file.path.dropFirst(prefix.count)) : file.path
                if latest[path] == nil { order.append(path) }
                let version = projection.fileSequences[file.path] ?? 0
                if version >= memberVersions[path, default: -1] {
                    latest[path] = file.status
                    memberVersions[path] = version
                }
            }
        }
        let partialConversation = conversationLoading || conversationHasMore || conversationHistoryIncomplete || conversationError != nil
        summaryModel = SummaryPaneModel(
            hero: base.hero, finalAnswer: base.finalAnswer, finalAnswerPlaceholder: base.finalAnswerPlaceholder,
            refusalLines: base.refusalLines, editedFilesAvailability: partialConversation ? .loading : base.editedFilesAvailability,
            editedFiles: order.map { EditedFile(path: $0, status: latest[$0] ?? .unconfirmed) },
            editedFilesNote: partialConversation ? "Conversation history is still loading; file accounting is incomplete." : base.editedFilesNote,
            numTurns: base.numTurns,
            inputTokens: base.inputTokens, outputTokens: base.outputTokens, costUSD: base.costUSD,
            additionalFileCount: summaries.reduce(0) { $0 + max(0, $1.totalFiles - $1.files.count) },
            onLoadMoreFiles: { [weak self] in
                guard let self, let member = conversationMembers.first(where: {
                    let projection = useCase.eventSummary(for: $0.taskID)
                    return projection.totalFiles > projection.files.count
                }) else { return }
                useCase.loadMoreSummaryFiles(member.taskID)
            }
        )
    }
}
