//
//  ParallelViewModelMock.swift
//  MainWindowFeature
//

#if DEBUG

import Foundation
import MonitorCore
import PbCommon

// MARK: - ParallelViewModelMock

/// Preview mock for `ParallelView`.
@MainActor
final class ParallelViewModelMock: ParallelViewModel {
    
    var groupName: String
    var headerSubtitle: String
    var statusSummary: String?
    var headerPills: [String]
    var headerClaimCaption: String
    var showPrompt: Bool
    var canCancelAll: Bool
    var isEmpty: Bool
    var columns: [ParallelColumnModel]

    init(
        groupName: String = "release-notes",
        headerSubtitle: String = "2 agents · read_only, write_in_repo · ~/repo · started 10:02 AM",
        statusSummary: String? = "1 running · 1 done",
        headerPills: [String] = ["No network"],
        headerClaimCaption: String = "",
        showPrompt: Bool = false,
        canCancelAll: Bool = true,
        isEmpty: Bool = false,
        columns: [ParallelColumnModel] = ParallelViewModelMock.sampleColumns()
    ) {
        self.groupName = groupName
        self.headerSubtitle = headerSubtitle
        self.statusSummary = statusSummary
        self.headerPills = headerPills
        self.headerClaimCaption = headerClaimCaption
        self.showPrompt = showPrompt
        self.canCancelAll = canCancelAll
        self.isEmpty = isEmpty
        self.columns = columns
    }
    
    func didAppear() {}
    func didDisappear() {}
    func didTapViewPrompt() { showPrompt.toggle() }
    func didTapCancelAll() {}
    
    static func sampleColumns() -> [ParallelColumnModel] {
        let running = TaskInfo(.object([
            "task_id": .string("abc123"), "backend": .string("claude"), "status": .string("running"),
            "started_at": .string(ISO8601DateFormatter().string(from: .now.addingTimeInterval(-90)))
        ]))!
        let done = TaskInfo(.object([
            "task_id": .string("def456"), "backend": .string("codex"), "status": .string("completed")
        ]))!
        let sampleRows = [
            ConversationTimelineRow(
                id: "abc123#1", taskID: "abc123", timestamp: .now,
                kind: .item(PreviewFixtures.textItem("Looked at the failing test.")), live: true
            )
        ]
        return [
            ParallelColumnModel(
                id: "abc123", task: running, title: "Fix the login bug", subtitle: "repo · Claude",
                isBusy: false, outcomeMessage: nil, showPrompt: false, prompt: nil,
                rows: sampleRows, activityRows: ActivityRowsBuilder.build(from: sampleRows), liveStep: nil,
                isLoading: false,
                summary: nil, stepCountText: "1 step", noToolCallsText: nil,
                onTapTakeover: {}, onTapOpenTask: {}
            ),
            ParallelColumnModel(
                id: "def456", task: done, title: "Refactor the parser", subtitle: "repo · Codex",
                isBusy: false, outcomeMessage: "Refused: read-only freedom.", showPrompt: false, prompt: nil,
                rows: [], activityRows: [], liveStep: nil, isLoading: false,
                summary: "Refactored the parser into smaller functions.", stepCountText: nil, noToolCallsText: nil,
                onTapTakeover: {}, onTapOpenTask: {}
            )
        ]
    }
}

#endif
