import Foundation
import MonitorCore

struct TaskDetailTimelineChild: Equatable, Sendable {
    let task: TaskInfo
    let title: String
}

struct TaskDetailTimelineInput: Equatable, Sendable {
    let task: TaskInfo
    let members: [ParallelMemberInput]
    let children: [TaskDetailTimelineChild]
    let start: Date?
    let isBuilder: Bool
    let events: [TaskEvent]
    let snapshot: TaskInfo?
    let history: EventHistoryState
}

struct TaskDetailTimelinePresentation: Equatable, Sendable {
    let rows: [ConversationTimelineRow]
    let activityRows: [ActivityRow]
    let children: [TaskDetailTimelineChild]
    let start: Date?
    let stepCount: Int
    let emptyText: String?
    let isLoading: Bool
    let liveStep: LiveStep?
    let pendingMessages: [PendingMessage]
    let history: EventHistoryState

    func loadingHistory() -> Self {
        Self(rows: rows, activityRows: activityRows, children: children, start: start, stepCount: stepCount,
            emptyText: emptyText, isLoading: isLoading, liveStep: liveStep, pendingMessages: pendingMessages,
            history: EventHistoryState(hasMore: history.hasMore, isLoading: true, error: nil, generation: history.generation))
    }
}

enum TaskDetailTimelineBuilder {
    nonisolated static func build(_ input: TaskDetailTimelineInput) throws -> TaskDetailTimelinePresentation {
        let timing = MonitorMetrics.begin()
        defer { MonitorMetrics.end(timing, stage: .detailBuild, backgroundThread: !Thread.isMainThread) }
        try Task.checkCancellation()
        var members: [ConversationItemMember] = []
        for member in input.members {
            try Task.checkCancellation()
            members.append(WorkflowBuilderPresentation.conversationMember(task: member.task,
                items: member.items, prompt: member.prompt, isBuilder: input.isBuilder))
        }
        let rawRows = try ParallelPresentationBuilder.rows(members)
        let rows = input.isBuilder ? WorkflowBuilderPresentation.visibleRows(rawRows)
        : WorkflowNodePresentation.visibleRows(rawRows, tasks: Dictionary(uniqueKeysWithValues: input.members.map { ($0.task.taskID, $0.task) }))
        try Task.checkCancellation()
        let count = rows.filter { if case .item = $0.kind { return true }; return false }.count
        let activity = ActivityRowsBuilder.build(from: rows, cancellationAware: true)
        try Task.checkCancellation()
        return TaskDetailTimelinePresentation(rows: rows, activityRows: activity, children: input.children,
            start: input.start, stepCount: count,
            emptyText: rows.isEmpty ? (input.task.status.isRunning ? "Waiting for the first event…"
                : "This task's event log is empty or was not found.") : nil,
            isLoading: count == 0 && input.members.contains { $0.availability == .loading },
            liveStep: LiveStep(rows: rows, isRunning: input.task.status.isRunning),
            pendingMessages: PendingMessage.visible(snapshot: input.snapshot, events: input.events), history: input.history)
    }
}

extension TaskDetailVM {
    func enqueueTimeline(_ input: TaskDetailTimelineInput) {
        let readyOperation = olderActivityRequest && (olderActivityReady || olderActivityObservedLoading)
            && timelineWorker == nil && !input.history.isLoading
        guard latestTimelineInput != input || readyOperation else { return }
        latestTimelineInput = input
        pendingTimelineInput = input
        timelineRevision &+= 1
        timelineWorker?.cancel()
        startPendingTimeline()
    }

    func startPendingTimeline() {
        guard timelineWorker == nil, let input = pendingTimelineInput else { return }
        pendingTimelineInput = nil
        let epoch = timelineEpoch
        let revision = timelineRevision
        let latency = MonitorMetrics.begin()
        let build = timelineBuild
        let worker = Task.detached(priority: .utility) { await build(input) }
        timelineWorker = Task { [weak self] in
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard let self else { return }
            timelineWorker = nil
            if timelineEpoch == epoch, timelineRevision == revision, let result {
                applyTimeline(result)
                MonitorMetrics.end(latency, stage: .detailUpdateLatency)
            }
            startPendingTimeline()
        }
    }

    func finishOlderActivityIfReady(_ value: TaskDetailTimelinePresentation) -> Bool {
        if olderActivityRequest, !value.history.isLoading,
           olderActivityReady || olderActivityObservedLoading || value.rows != appliedTimelinePresentation?.rows || value.history.error != nil {
            olderActivityRequest = false
            olderActivityObservedLoading = false
            activityPaginationRevision &+= 1
            return true
        }
        return false
    }

    func applyTimeline(_ value: TaskDetailTimelinePresentation) {
        let timing = MonitorMetrics.begin()
        var writes = 0
        defer { MonitorMetrics.end(timing, stage: .detailApply, renderingWrites: writes) }
        let operationCompleted = finishOlderActivityIfReady(value)
        guard appliedTimelinePresentation != value || operationCompleted else { return }
        appliedTimelinePresentation = value
        writes = 1
        let strip: SubTaskStripModel? = value.children.isEmpty ? nil : SubTaskStripModel(
            children: value.children.map { SubTaskEntry(task: $0.task, title: $0.title) }, start: value.start,
            onSelectTask: { [weak self] id in self?.didTapTask(id) })
        timelineModel = TimelinePaneModel(stepCountText: "\(value.stepCount) steps", rows: value.rows,
            activityRows: value.activityRows, start: value.start, emptyText: value.emptyText,
            subTaskStrip: strip, isLoading: value.isLoading, liveStep: value.liveStep,
            updateToken: ActivityUpdateToken(rows: value.rows, liveStep: value.liveStep, pendingMessages: value.pendingMessages),
            pendingMessages: value.pendingMessages, history: value.history,
            paginationRevision: activityPaginationRevision, onLoadMore: { [weak self] in self?.loadMoreConversationActivity() ?? false })
    }
}
