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

    var tab: TaskTab = .timeline
    var tabs: [TaskTab] = [.timeline, .summary, .prompt, .raw]

    var timelineModel = TimelinePaneModel(
        stepCountText: "1 step",
        rows: [ConversationTimelineRow(
            id: "abc12345#1", taskID: "abc12345", timestamp: .now.addingTimeInterval(-15),
            kind: .item(PreviewFixtures.textItem("Looked at the failing test.")), live: true
        )],
        start: .now.addingTimeInterval(-30), emptyText: nil, subTaskStrip: nil
    )
    var summaryModel = SummaryPaneModel.empty
    var promptText = "Fix the flaky login test."
    var rawEvents: [TaskEvent] = []
    var rawEventsPath = "/tmp/abc12345.events.jsonl"
    var inspectorModel: InspectorModel? = InspectorModel(
        task: TaskDetailViewModelMock.sampleTask(), current: nil, stepCount: 1,
        activity: ActivityCounts(), subtaskCount: 0, ancestors: [], siblings: [],
        detail: TaskDetailViewModelMock.sampleTask(), hasSnapshot: false, notices: [], onSelectTask: { _ in }
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
    @discardableResult func submitMessage(_: String) -> Bool { true }

    static func sampleTask() -> TaskInfo {
        TaskInfo(.object([
            "task_id": .string("abc12345"), "backend": .string("claude"), "status": .string("running"),
            "started_at": .string(ISO8601DateFormatter().string(from: .now.addingTimeInterval(-90))),
            "repo_path": .string("/Users/example/repo")
        ]))!
    }
}

#endif
