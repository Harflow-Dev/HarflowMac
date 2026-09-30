//
//  TaskDetailVM+Timeline.swift
//  MainWindowFeature
//
//  The Timeline tab, the Prompt tab's text, and Raw Events. Unknown events never enter
//  `latestItems` (`Timeline.items(from:)` already drops `.unknown` — MS-DETAIL-6), so they can only
//  ever appear in `rawEvents` (all decoded events, `TaskDetailVM.didAppear`/`itemsPublisher` sink).
//
//  Monitor piece 7: the Timeline concatenates every conversation member's own paired events
//  (`MonitorCore.ConversationTimeline`, task-scoped pairing per Review round 1, item 1), oldest to
//  newest, with a turn separator ahead of every follow-up. Raw Events and the events-path label stay
//  scoped to the conversation's CURRENT member only — a per-process debug view, not a merged one.
//
//  Monitor piece 8, Codex review round 2, finding 2: this reads each member's own ALREADY-BUILT
//  `itemsByMember` (the repository's incremental `TimelineBuilder` snapshot, kept current by
//  `TaskDetailVM.acquireMemberLease`'s `itemsPublisher` subscription) via
//  `ConversationTimeline.rows(itemMembers:)` — never `ConversationMember`/`rows(members:)`, which
//  would rebuild every member's whole timeline from raw events on every single publication.
//

import Foundation
import MonitorCore

extension TaskDetailVM {

    /// Rebuilds the Timeline tab's model: the concatenated conversation rows, whether the task is
    /// live (per-turn — a running spinner never appears on an older, already-terminal turn even
    /// while the newest one runs), and the sub-task strip (children of ANY member, Design point 3).
    /// `allChildren` is `recompute()`'s own `allConversationChildren()` result (Monitor piece 11) —
    /// shared with `recomputeInspector`'s subtask count instead of each recomputing it separately.
    func recomputeTimeline(task: TaskInfo, allChildren: [TaskInfo]) {
        let members = conversationMembers
        let start = members.first?.startedAt
        let conversationTimelineMembers = members.map {
            ConversationItemMember(task: $0, items: itemsByMember[$0.taskID] ?? [], prompt: useCase.prompt(for: $0.taskID))
        }
        let rows = ConversationTimeline.rows(itemMembers: conversationTimelineMembers)
        let subTaskStrip: SubTaskStripModel? = allChildren.isEmpty ? nil : SubTaskStripModel(
            children: allChildren.map { SubTaskEntry(task: $0, title: useCase.title($0.taskID)) },
            start: start,
            onSelectTask: { [weak self] id in self?.didTapTask(id) }
        )
        let itemCount = rows.filter { if case .item = $0.kind { return true }; return false }.count
        // Plan review round 1, item 4: a shimmer only while no member has any REAL content yet
        // (ignoring synthetic separator rows — `itemCount`, not `rows.count`) AND at least one
        // member's own event stream is still `.loading` — never once real content exists, and never
        // for `.unavailable` (that keeps today's honest empty-log message).
        let isLoading = itemCount == 0 && members.contains { (eventsAvailabilityByMember[$0.taskID] ?? .loading) == .loading }
        let liveStep = LiveStep(rows: rows)
        timelineModel = TimelinePaneModel(
            stepCountText: "\(itemCount) steps",
            rows: rows,
            activityRows: ActivityRowsBuilder.build(from: rows),
            start: start,
            emptyText: rows.isEmpty
            ? (task.status.isRunning ? "Waiting for the first event…" : "This task's event log is empty or was not found.")
            : nil,
            subTaskStrip: subTaskStrip,
            isLoading: isLoading,
            liveStep: liveStep,
            updateToken: ActivityUpdateToken(rows: rows, liveStep: liveStep)
        )
        // Design point 6: the Prompt tab shows the FIRST task's own prompt — the conversation's name.
        promptText = useCase.prompt(for: members[0].taskID)
        ?? "The prompt is recorded in the task's event log, which has not been read yet (or does not exist)."
        rawEventsPath = useCase.eventsPath(for: currentTaskID)
        rawEvents = eventsByMember[currentTaskID] ?? []
    }
}
