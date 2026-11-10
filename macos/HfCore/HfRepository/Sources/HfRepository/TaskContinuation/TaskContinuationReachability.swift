import Foundation
import MonitorCore

// MARK: - TaskContinuationReachability

/// A targeted positive-path read. Exhaustion never claims descendant absence.
struct TaskContinuationReachability {
    let taskList: any TaskListRepository
    let now: @Sendable () -> ContinuousClock.Instant

    func observe(_ request: TaskContinuationRequest, target: String) async -> TaskContinuationCheck {
        guard !target.isEmpty, target != request.sourceTaskID else { return .inconclusive }
        var traversal = Traversal(deadline: now().advanced(by: .seconds(120)), queue: [request.sourceTaskID])
        do {
            while traversal.offset < traversal.queue.count {
                let predecessor = traversal.queue[traversal.offset]
                traversal.offset += 1
                guard let edges = try await expand(predecessor, runtime: request.runtime, traversal: &traversal) else {
                    return .inconclusive
                }
                if edges.contains(target) { return .reachable(sourceTaskID: target) }
                for edge in edges where !traversal.queue.contains(edge) {
                    traversal.queue.append(edge)
                }
            }
        } catch {
            return .failed(QualificationFailure(error: error))
        }
        return .inconclusive
    }

    private func expand(_ predecessor: String, runtime: QualificationRuntimeToken,
                        traversal: inout Traversal) async throws -> [String]? {
        var cursor: String?
        var cursors = Set<String>()
        var identifiers = Set<String>()
        while traversal.pages < 4 {
            guard !Task.isCancelled, now() < traversal.deadline else { return nil }
            traversal.pages += 1
            let page = try await taskList.successorPage(predecessorTaskID: predecessor, cursor: cursor, runtime: runtime)
            guard !Task.isCancelled, now() < traversal.deadline, page.predecessorTaskID == predecessor else { return nil }
            let history = page.history.page
            traversal.rows += history.items.count + history.relatedHeaders.count
            guard traversal.rows <= 400, !page.readinessUnknown, history.catalogState.isReady,
                  !history.bootstrapPending, !history.historyIncomplete, !history.authorityIncomplete else { return nil }
            for item in page.history.items {
                guard !item.taskID.isEmpty, item.taskID != predecessor, identifiers.insert(item.taskID).inserted,
                      item.parentTaskID == predecessor || item.raw["continuation_of_task_id"]?.stringValue == predecessor else { return nil }
            }
            if !history.hasMore { return identifiers.sorted() }
            guard let next = history.nextCursor, next != cursor, cursors.insert(next).inserted else { return nil }
            cursor = next
        }
        return nil
    }

    private struct Traversal {
        let deadline: ContinuousClock.Instant
        var queue: [String]
        var offset = 0
        var pages = 0
        var rows = 0
    }
}
