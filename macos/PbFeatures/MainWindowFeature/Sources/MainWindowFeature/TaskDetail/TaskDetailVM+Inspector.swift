//
//  TaskDetailVM+Inspector.swift
//  MainWindowFeature
//
//  The Inspector's model, split out of `TaskDetailVM.swift` to keep it under the lint limits
//  (redesign phase 5).
//

import Foundation
import MonitorCore
import PbUI

extension TaskDetailVM {

    /// "Now" (the current running tool), lineage, and the raw-snapshot "Details"/enforcement.
    /// It aggregates data the other extensions already computed plus core lineage. Activity and sub-task count are summed across
    /// every conversation member (Design point 3: "children of any member hang under the
    /// conversation's node"); "Now" reads the current member alone, since only it can be running.
    /// `ancestors` and `siblings` are both about the CURRENT task's own position (Codex review
    /// round 1, finding 4) — never the conversation's first member, whose own ancestors do not
    /// necessarily reach the current task at all. `allChildren` is `recompute()`'s own
    /// `allConversationChildren()` result, passed in rather than recomputed here (Monitor piece 11):
    /// this used to make its OWN separate `useCase.children(of:)` call per member just to count them,
    /// duplicating `recomputeTimeline`'s identical per-member query.
    func recomputeInspector(task: TaskInfo, ancestors: [TaskInfo], allChildren: [TaskInfo]) {
        let siblings = useCase.siblings(of: currentTaskID)
        let snapshot = useCase.snapshot(currentTaskID)
        let detail = snapshot ?? task
        let activity = conversationMembers.reduce(ActivityCounts()) { acc, member in
            let memberActivity = useCase.activity(for: member.taskID)
            var result = acc
            result.toolCalls += memberActivity.toolCalls
            result.edits += memberActivity.edits
            result.commands += memberActivity.commands
            return result
        }
        let subtaskCount = allChildren.count
        inspectorModel = InspectorModel(
            task: task,
            current: useCase.current(for: currentTaskID),
            stepCount: timelineModel.rows.filter { if case .item = $0.kind { return true }; return false }.count,
            activity: activity,
            activityNote: conversationLoading || conversationHasMore || conversationHistoryIncomplete || conversationError != nil
                || conversationMembers.contains(where: { useCase.eventSummary(for: $0.taskID).availability != .available })
                ? "Partial activity totals while history or summaries are loading or unavailable." : nil,
            subtaskCount: subtaskCount,
            ancestors: ancestors.map { SubTaskEntry(task: $0, title: useCase.title($0.taskID)) },
            siblings: siblings.map { SubTaskEntry(task: $0, title: useCase.title($0.taskID)) },
            detail: detail,
            hasSnapshot: snapshot != nil,
            notices: InspectorModel.distinctNotices(task.notices),
            // Summary-tab item 15: "What was enforced" moved from the Summary tab to the
            // Inspector's "Technical info" disclosure — mapped here (decision 9) from the same
            // `PbUI.EnforcementText` source, read off the snapshot-or-listing `detail` exactly
            // like the "not recorded" rule beside it.
            enforcementLines: EnforcementText.lines(detail.enforcement),
            startedBy: startedByText(),
            resumeCommand: resumeCommand,
            onCopyResumeCommand: { [weak self] in self?.didTapCopyResumeCommand() },
            onCopyTaskID: { [weak self] in self?.didTapCopyTaskID() },
            onSelectTask: { [weak self] id in self?.didTapTask(id) }
        )
    }

    /// "Started by" (settled plan D17): the title of the task that called polybridge to start this
    /// conversation when one is recorded, else "Top-level task". Read from the conversation's first
    /// member, like the spawned-by banner and "Open parent".
    private func startedByText() -> String {
        let parentID = conversationMembers.first.flatMap { $0.isRoot ? nil : $0.spawnedBy }
        return InspectorModel.startedByText(parentTitle: parentID.map { useCase.title($0) })
    }
}
