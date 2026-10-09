import Foundation
import MonitorCore

/// Values cross the worker boundary; navigation and observation stay on the main actor.
struct ParallelColumnPresentation: Equatable, Sendable {
    var id: String
    let task: TaskInfo
    let title: String
    let subtitle: String
    let isBusy: Bool
    let outcomeMessage: String?
    var showPrompt: Bool
    let prompt: String?
    var rows: [ConversationTimelineRow] = []
    var activityRows: [ActivityRow] = []
    var liveStep: LiveStep?
    var pendingMessages: [PendingMessage] = []
    var isLoading = true
    var emptyText: String?
    var history = EventHistoryState()
    var paginationRevision = 0
    var summary: String?
    let start: Date?
    let memberTaskIDs: Set<String>
}

struct ParallelMemberInput: Equatable, Sendable {
    let task: TaskInfo
    let items: [TimelineItem]
    let prompt: String?
    let availability: EventAvailability
}

struct ParallelColumnInput: Equatable, Sendable {
    var base: ParallelColumnPresentation
    let members: [ParallelMemberInput]
    let events: [TaskEvent]
    let snapshot: TaskInfo?
}

typealias ParallelColumnsBuild = @Sendable ([String: ParallelColumnInput]) async -> [String: ParallelColumnPresentation]?

enum ParallelPresentationBuilder {
    private nonisolated static func isBackgroundThread() -> Bool { !Thread.isMainThread }

    nonisolated static func buildColumns(_ inputs: [String: ParallelColumnInput]) async -> [String: ParallelColumnPresentation]? {
        let start = MonitorMetrics.begin()
        var built = 0
        defer { MonitorMetrics.end(start, stage: .parallelBuild, backgroundThread: isBackgroundThread(), builtColumns: built) }
        do {
            var result: [String: ParallelColumnPresentation] = [:]
            for (id, input) in inputs {
                try Task.checkCancellation()
                result[id] = try build(input)
                built += 1
            }
            return result
        } catch { return nil }
    }

    nonisolated static func build(_ input: ParallelColumnInput) throws -> ParallelColumnPresentation {
        try Task.checkCancellation()
        var members: [ConversationItemMember] = []
        for member in input.members {
            try Task.checkCancellation()
            members.append(ConversationItemMember(task: member.task, items: member.items, prompt: member.prompt))
        }
        let rawRows = try rows(members)
        try Task.checkCancellation()
        let tasks = Dictionary(uniqueKeysWithValues: members.map { ($0.task.taskID, $0.task) })
        let rows = WorkflowNodePresentation.visibleRows(rawRows, tasks: tasks, compact: true)
        try Task.checkCancellation()
        var result = input.base
        if WorkflowNodePresentation.isManaged(result.task) || WorkflowNodePresentation.resultError(result.task) != nil {
            result.summary = WorkflowNodePresentation.summary(input.snapshot?.summary, task: result.task)
        }
        result.rows = rows
        result.activityRows = ActivityRowsBuilder.build(from: rows, cancellationAware: true)
        try Task.checkCancellation()
        result.liveStep = LiveStep(rows: rows, isRunning: result.task.status.isRunning)
        result.pendingMessages = PendingMessage.visible(snapshot: input.snapshot, events: input.events)
        let hasItems = input.members.contains { !$0.items.isEmpty }
        result.isLoading = !hasItems && (input.members.contains { $0.availability == .loading }
            || (input.members.isEmpty && input.base.history.isLoading))
        result.emptyText = nil
        if !result.isLoading, !hasItems, result.history.error == nil {
            result.emptyText = input.members.contains { $0.availability == .unavailable }
                ? "Activity log unavailable." : "No activity to display."
        }
        return result
    }

    /// Same canonical concatenation as ConversationTimeline, with checkpoints for long feeds.
    nonisolated static func rows(_ members: [ConversationItemMember]) throws -> [ConversationTimelineRow] {
        var rows: [ConversationTimelineRow] = []
        for (index, member) in members.enumerated() {
            try Task.checkCancellation()
            let live = index == members.count - 1 && member.task.status.isRunning
            if index > 0 {
                rows.append(ConversationTimelineRow(id: "sep:\(member.task.taskID)", taskID: member.task.taskID,
                    timestamp: member.task.startedAt, kind: .separator(text: member.prompt ?? ""), live: false))
            }
            for item in member.items {
                try Task.checkCancellation()
                if index > 0, case .message(let text, let source) = item.body, source == "initial", text == member.prompt { continue }
                if index > 0, case .started = item.body { continue }
                rows.append(ConversationTimelineRow(id: "\(member.task.taskID)#\(item.id)", taskID: member.task.taskID,
                    timestamp: item.at, kind: .item(item), live: live))
            }
        }
        return rows
    }

}

/// Residency is based on geometry, never SwiftUI's speculative appearance callbacks.
enum ParallelResidency {
    nonisolated static func visibleIndices(count: Int, offset: CGFloat, width: CGFloat, stride: CGFloat) -> Range<Int> {
        guard count > 0, width.isFinite, width > 0, offset.isFinite, stride.isFinite, stride > 0 else { return 0 ..< 0 }
        let left = min(max(0, offset), max(0, CGFloat(count) * stride - width))
        return min(count - 1, Int(floor(left / stride))) ..< min(count, Int(ceil((left + width) / stride)))
    }

    nonisolated static func indices(count: Int, offset: CGFloat, width: CGFloat, stride: CGFloat) -> Range<Int> {
        guard count > 0, width.isFinite, width > 0, offset.isFinite, stride.isFinite, stride > 0 else { return 0 ..< 0 }
        let maximum = max(0, CGFloat(count) * stride - width)
        let left = min(max(0, offset), maximum)
        let first = min(count - 1, Int(floor(left / stride)))
        let end = min(count, Int(ceil((left + width) / stride)))
        return max(0, first - 1) ..< min(count, end + 1)
    }
}

struct ParallelColumnRenderValue: Equatable {
    let presentation: ParallelColumnPresentation
    let animatesArrival: Bool
    let isResident: Bool
    let isVisible: Bool
}

extension ParallelColumnModel {
    var renderValue: ParallelColumnRenderValue {
        var value = ParallelColumnPresentation(id: id, task: task, title: title, subtitle: subtitle,
            isBusy: isBusy, outcomeMessage: outcomeMessage, showPrompt: showPrompt, prompt: prompt,
            summary: summary, start: start, memberTaskIDs: memberTaskIDs)
        value.rows = rows
        value.activityRows = activityRows
        value.liveStep = liveStep
        value.pendingMessages = pendingMessages
        value.isLoading = isLoading
        value.emptyText = emptyText
        value.history = history
        value.paginationRevision = paginationRevision
        return ParallelColumnRenderValue(presentation: value, animatesArrival: animatesArrival, isResident: isResident, isVisible: isVisible)
    }
}
