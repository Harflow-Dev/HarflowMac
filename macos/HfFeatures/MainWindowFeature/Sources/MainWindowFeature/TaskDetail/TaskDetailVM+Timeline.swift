//
//  TaskDetailVM+Timeline.swift
//  MainWindowFeature
//
//  The Activity timeline model, the prompt text, and the raw events. Unknown events never enter
//  `latestItems` (`Timeline.items(from:)` already drops `.unknown` — MS-DETAIL-6), so they can only
//  ever appear in `rawEvents` (all decoded events, `TaskDetailVM.didAppear`/`itemsPublisher` sink).
//
//  Monitor piece 7: the Timeline concatenates every conversation member's own paired events
//  (`MonitorCore.ConversationTimeline`, task-scoped pairing per Review round 1, item 1), oldest to
//  newest, with a turn separator ahead of every follow-up. The raw events and the events-path label stay
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

    /// Only the standalone mount draws the Summary entry.
    var showsSummaryEntry: Bool { chrome == .standalone }

    func activityHistory(_ members: [TaskInfo]) -> EventHistoryState {
        let states = members.map { observationFrames[$0.taskID]?.presentationHistory ?? EventHistoryState(isLoading: true) }
        return EventHistoryState(
            hasMore: states.contains(where: \.hasMore) || conversationHasMore
                || conversationMembers.contains(where: { !loadedActivityMembers.contains($0.taskID) }),
            isLoading: states.contains(where: \.isLoading) || conversationLoading,
            error: states.compactMap(\.error).first ?? conversationError ?? useCase.successorObservationError,
            generation: states.map(\.generation).max() ?? 0
        )
    }

    @discardableResult func loadMoreConversationActivity() -> Bool {
        guard !olderActivityRequest, !conversationLoading else { return false }
        let loaded = conversationMembers.filter { loadedActivityMembers.contains($0.taskID) }
        guard !loaded.contains(where: { observationFrames[$0.taskID]?.history.isLoading ?? true }) else { return false }
        let hasCandidate = loaded.contains { observationFrames[$0.taskID]?.history.availableActions.contains(.loadEarlier) == true }
            || conversationMembers.contains { !loadedActivityMembers.contains($0.taskID) }
            || conversationHasMore || conversationError != nil
        guard hasCandidate else { return false }
        olderActivityRequest = true
        olderActivityObservedLoading = false
        olderActivityMember = nil
        olderActivityReady = false
        if let member = loaded.first(where: {
            let state = observationFrames[$0.taskID]?.presentationHistory ?? EventHistoryState(isLoading: true)
            return state.hasMore
        }) {
            olderActivityMember = member.taskID
            olderActivityHistory = observationFrames[member.taskID]?.presentationHistory ?? EventHistoryState(isLoading: true)
            guard let frame = observationFrames[member.taskID], useCase.requestObservation(.loadEarlier, for: member.taskID, scope: frame.scope) else {
                olderActivityRequest = false
                olderActivityMember = nil
                olderActivityHistory = nil
                recompute()
                return false
            }
        } else if let previous = conversationMembers.last(where: { !loadedActivityMembers.contains($0.taskID) }) {
            loadedActivityMembers.insert(previous.taskID)
            acquireMemberLease(previous.taskID)
            olderActivityReady = true
            recompute()
        } else if conversationHasMore || conversationError != nil {
            loadConversationHistory(initial: false)
        } else {
            olderActivityRequest = false
        }
        if olderActivityRequest, let presentation = appliedTimelinePresentation {
            applyTimeline(presentation.loadingHistory())
        }
        recompute()
        return olderActivityRequest
    }

    /// Rebuilds the Activity timeline's model: the concatenated conversation rows, whether the task is
    /// live (per-turn — a running spinner never appears on an older, already-terminal turn even
    /// while the newest one runs), and the sub-task strip (children of ANY member, Design point 3).
    /// `allChildren` is `recompute()`'s own `allConversationChildren()` result (Monitor piece 11) —
    /// shared with `recomputeInspector`'s subtask count instead of each recomputing it separately.
    func recomputeTimeline(task: TaskInfo, allChildren: [TaskInfo]) {
        let preparation = MonitorMetrics.begin()
        defer { MonitorMetrics.end(preparation, stage: .detailPreparation) }
        let members = conversationMembers.filter { loadedActivityMembers.contains($0.taskID) }
        if let id = olderActivityMember, let previous = olderActivityHistory {
            let current = observationFrames[id]?.presentationHistory ?? EventHistoryState(isLoading: true)
            if !current.isLoading, current != previous { olderActivityReady = true }
        }
        let history = activityHistory(members)
        if history.isLoading { olderActivityObservedLoading = true }
        let input = TaskDetailTimelineInput(
            task: task, members: members.map { member in
                ParallelMemberInput(task: member, items: itemsByMember[member.taskID] ?? [],
                    prompt: nil,
                    availability: eventsAvailabilityByMember[member.taskID] ?? .loading, observation: observationFrames[member.taskID])
            }, children: allChildren.map { TaskDetailTimelineChild(task: $0, title: useCase.title($0.taskID)) },
            start: conversationMembers.first?.startedAt, isBuilder: isWorkflowBuilder,
            events: eventsByMember[currentTaskID] ?? [], snapshot: useCase.snapshot(currentTaskID), history: history,
            turnsText: turnsText, showsSummaryEntry: showsSummaryEntry)
        enqueueTimeline(input)
        let nextEvents = observationFrames[currentTaskID]?.events ?? []
        if rawEvents != nextEvents { rawEvents = nextEvents }
    }
}
