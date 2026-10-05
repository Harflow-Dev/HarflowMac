//
//  TaskDetailViewModelMock.swift
//  MainWindowFeature
//

#if DEBUG

import Foundation
import MonitorCore
import PbCommon
import PbRepository

// MARK: - TaskDetailViewModelMock

/// Preview mock for `TaskDetailView`.
@MainActor
final class TaskDetailViewModelMock: TaskDetailViewModel {

    let taskID = "abc12345"
    var task: TaskInfo? = TaskDetailViewModelMock.sampleTask()
    var hasListed = true

    var title = "Fix the login bug"
    var ancestorCrumbs: [AncestorCrumb] = []
    var isBusy = false
    var polybridgeApprovalBackend: String? { nil }
    func didTapAllowPolybridgeTools() {}
    var outcomeMessage: String?
    var takenOverBannerText: String?
    var spawnedByBannerText: String?
    var canTakeover = true
    var takeoverButtonLabel = "Take over"
    var takeoverHelp = "Stop the headless run and resume the session interactively."
    var openParentTaskID: String?
    var canCancel = true
    var resumeCommand: String? = "cd /Users/example/repo && claude --resume abc12345"
    var copyResumeCommandHelp = "Copies a command that resumes this session in your own terminal."
    var turnsText: String?

    var tab: TaskTab = .activity
    var tabs: [TaskTab] = [.activity, .summary, .prompt]

    var timelineModel = TimelinePaneModel(
        stepCountText: "1 step",
        rows: [ConversationTimelineRow(
            id: "abc12345#1", taskID: "abc12345", timestamp: .now.addingTimeInterval(-15),
            kind: .item(PreviewFixtures.textItem("Looked at the failing test.")), live: true
        )],
        start: .now.addingTimeInterval(-30), emptyText: nil, subTaskStrip: nil, isLoading: false
    )
    var summaryModel = SummaryPaneModel.empty
    var promptText = "Fix the flaky login test."
    var rawEvents: [TaskEvent] = []
    var rawEventsPath = "/tmp/abc12345.events.jsonl"
    var inspectorModel: InspectorModel? = InspectorModel(
        task: TaskDetailViewModelMock.sampleTask(), current: nil, stepCount: 1,
        activity: ActivityCounts(), subtaskCount: 0, ancestors: [], siblings: [],
        detail: TaskDetailViewModelMock.sampleTask(), hasSnapshot: false, notices: [],
        startedBy: "Top-level task", resumeCommand: "cd /Users/example/repo && claude --resume abc12345",
        onCopyResumeCommand: {}, onCopyTaskID: {}, onSelectTask: { _ in }
    )
    var messageBoxModel = MessageBoxModel(
        canSend: true, canContinue: false, isBusy: false, label: "Message this task",
        hint: "Queued; folded into the current turn or sent after it", placeholder: "Message this task while it runs…",
        buttonLabel: "Send"
    )

    func didAppear() {}
    func didDisappear() {}
    func didSelectTab(_ tab: TaskTab) { self.tab = tab }
    func didTapTask(_: String) {}
    func didTapTakeover() {}
    func didTapCancel() {}
    func didTapCopyResumeCommand() {}
    func didTapCopyTaskID() {}
    func didTapCopyRepoPath() {}
    var loadingHeader: TaskLoadingHeader? = TaskLoadingHeader(title: "Fix the login bug", repoName: "repo")
    @discardableResult func submitMessage(_: String) -> Bool { true }

    /// A finished task: "Continue in terminal", the composer offering a follow-up, no cancel.
    static func finished() -> TaskDetailViewModelMock {
        let mock = TaskDetailViewModelMock()
        mock.task = sampleTask(status: "completed")
        mock.takeoverButtonLabel = "Continue in terminal"
        mock.canCancel = false
        mock.messageBoxModel = MessageBoxModel(
            canSend: false, canContinue: true, isBusy: false, label: "Continue this session",
            hint: "Continues the same agent session; the reply appears below as a new turn",
            placeholder: "Send a follow-up — it continues this conversation", buttonLabel: "Continue"
        )
        return mock
    }

    static func sampleTask(status: String = "running", takenOver: Bool = false, spawnedBy: String? = nil) -> TaskInfo {
        var object: [String: JSONValue] = [
            "task_id": .string("abc12345"), "backend": .string("claude"), "status": .string(status),
            "started_at": .string(ISO8601DateFormatter().string(from: .now.addingTimeInterval(-90))),
            "repo_path": .string("/Users/example/repo"), "freedom": .string("write_in_repo"), "taken_over": .bool(takenOver)
        ]
        if status != "running" { object["duration_seconds"] = .number(84) }
        if let spawnedBy { object["spawned_by"] = .string(spawnedBy) }
        return TaskInfo(.object(object))!
    }
}

#endif
