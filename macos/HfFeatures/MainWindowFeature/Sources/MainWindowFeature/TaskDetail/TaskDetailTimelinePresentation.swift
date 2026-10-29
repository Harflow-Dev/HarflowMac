import Foundation
import HfUI
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
    /// The header's existing conversation-turn text ("N turns"/"N decisions", `nil` for a plain
    /// never-followed-up task), passed through to the pane — conversation members, never the
    /// backend's own `numTurns`.
    var turnsText: String?
    var previousActivitySnapshot: ActivityFeedSnapshot?
    var previousMarkdown: [String: StreamingMarkdownState] = [:]
}

struct TaskDetailTimelinePresentation: Equatable, Sendable {
    let rows: [ConversationTimelineRow]
    let activityRows: [ActivityRow]
    let children: [TaskDetailTimelineChild]
    let start: Date?
    let stepCount: Int
    /// The header's activity-item count, `nil` while no item row is loaded — a
    /// zero or still-loading count is omitted rather than claimed as "0 activity items".
    let stepCountText: String?
    /// The header's conversation-turn text, passed through from the input.
    let turnsText: String?
    /// "No tool calls recorded", proven only for a terminal task from the UNFILTERED member inputs (a nonempty
    /// member set, every member's own log read completely, no more/loading/error history, and no
    /// tool item anywhere) — never from the filtered display rows alone, which managed/builder
    /// presentation may intentionally hide calls from.
    let noToolCallsText: String?
    let emptyText: String?
    let isLoading: Bool
    let liveStep: LiveStep?
    let pendingMessages: [PendingMessage]
    var workMessages: [WorkMessageBubble] = []
    let history: EventHistoryState

    var activitySnapshot: ActivityFeedSnapshot?
    var markdown: [String: StreamingMarkdownState] = [:]

    func loadingHistory() -> Self {
        Self(rows: rows, activityRows: activityRows, children: children, start: start, stepCount: stepCount,
            stepCountText: stepCountText, turnsText: turnsText, noToolCallsText: nil,
            emptyText: emptyText, isLoading: isLoading, liveStep: liveStep, pendingMessages: pendingMessages,
            workMessages: workMessages,
            history: EventHistoryState(hasMore: history.hasMore, isLoading: true, error: nil, generation: history.generation),
            activitySnapshot: activitySnapshot, markdown: markdown)
    }

    /// The history half of the no-tool proof (§4/§8); the builder separately requires a terminal task.
    /// The claim needs a nonempty member input set, ALL of those
    /// members' own logs read completely (`.available`), a settled history window (no error, no
    /// more pages, not loading) and no tool item in the unfiltered member inputs. Filtered display
    /// rows alone can never prove it.
    nonisolated static func noToolCallsRecorded(members: [ParallelMemberInput], history: EventHistoryState) -> Bool {
        guard !members.isEmpty else { return false }
        guard members.allSatisfy({ $0.availability == .available }) else { return false }
        guard history.error == nil, !history.hasMore, !history.isLoading else { return false }
        return members.allSatisfy { member in
            member.items.allSatisfy { item in
                if case .tool = item.body { return false }
                return true
            }
        }
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
        let markdown = ActivityRowsBuilder.markdownSnapshot(from: rows, previous: input.previousMarkdown)
        let activity = ActivityRowsBuilder.build(from: rows, cancellationAware: true, markdown: markdown)
        let noTools = input.task.status.isTerminal
            && TaskDetailTimelinePresentation.noToolCallsRecorded(members: input.members, history: input.history)
        try Task.checkCancellation()
        return TaskDetailTimelinePresentation(rows: rows, activityRows: activity, children: input.children,
            start: input.start, stepCount: count,
            stepCountText: count > 0 ? "\(count) \(count == 1 ? "activity item" : "activity items")" : nil,
            turnsText: input.turnsText,
            noToolCallsText: noTools ? "No tool calls recorded" : nil,
            emptyText: rows.isEmpty && !noTools ? (input.task.status.isRunning ? "Waiting for the first event…"
                : "This task's event log is empty or was not found.") : nil,
            isLoading: count == 0 && input.members.contains { $0.availability == .loading },
            liveStep: LiveStep(rows: rows, isRunning: input.task.status.isRunning),
            pendingMessages: PendingMessage.visible(snapshot: input.snapshot, events: input.events),
            workMessages: WorkMessageBubble.project(raw: input.snapshot?.raw ?? input.task.raw),
            history: input.history,
            activitySnapshot: ActivityFeedSnapshot.preparing(activity, previous: input.previousActivitySnapshot), markdown: markdown)
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
        guard timelineWorker == nil, var input = pendingTimelineInput else { return }
        input.previousActivitySnapshot = appliedTimelinePresentation?.activitySnapshot
        input.previousMarkdown = appliedTimelinePresentation?.markdown ?? [:]
        pendingTimelineInput = nil
        let epoch = timelineEpoch
        let revision = timelineRevision
        let latency = MonitorMetrics.begin()
        let build = timelineBuild
        let appliedInput = input
        let worker = Task.detached(priority: .utility) { await build(appliedInput) }
        timelineWorker = Task { [weak self] in
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard let self else { return }
            timelineWorker = nil
            if timelineEpoch == epoch, timelineRevision == revision, let result {
                appliedTimelineInput = appliedInput
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
        timelineModel = TimelinePaneModel(stepCountText: value.stepCountText, turnsText: value.turnsText,
            noToolCallsText: value.noToolCallsText, rows: value.rows,
            activityRows: value.activityRows, start: value.start, emptyText: value.emptyText,
            subTaskStrip: strip, isLoading: value.isLoading, liveStep: value.liveStep,
            updateToken: ActivityUpdateToken(rows: value.rows, liveStep: value.liveStep, pendingMessages: value.pendingMessages),
            pendingMessages: value.pendingMessages, history: value.history,
            paginationRevision: activityPaginationRevision, onLoadMore: { [weak self] in self?.loadMoreConversationActivity() ?? false })
        timelineModel.activitySnapshot = value.activitySnapshot
        timelineModel.workMessages = WorkMessageBubble.applying(value.workMessages, notes: messageNotes)
        timelineModel.onCancelQueuedMessage = { [weak self] id in self?.cancelQueuedMessage(id) }
        timelineModel.onSelectTask = { [weak self] id in self?.didTapTask(id) }
    }
}
