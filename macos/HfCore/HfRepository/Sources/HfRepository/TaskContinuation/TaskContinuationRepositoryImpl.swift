import Combine
import Foundation
import MonitorCore

// MARK: - TaskContinuationRepositoryImpl

/// Retains bounded session evidence without evicting unsafe invocation history.
public final class TaskContinuationRepositoryImpl: TaskContinuationRepository, @unchecked Sendable {
    private let tooling: any ToolEnvironmentRepository
    private let taskList: any TaskListRepository
    private let actions: any TaskActionRepository
    private let now: @Sendable () -> ContinuousClock.Instant
    private let lock = NSLock()
    private let changes = PassthroughSubject<Void, Never>()
    private var records: [TaskContinuationAttempt] = []
    private var reads: [UUID: UUID] = [:]

    public init(tooling: any ToolEnvironmentRepository, taskList: any TaskListRepository,
                actions: any TaskActionRepository, now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.tooling = tooling
        self.taskList = taskList
        self.actions = actions
        self.now = now
    }

    public func state(for request: TaskContinuationRequest) -> TaskContinuationAttempt? {
        lock.withLock {
            records.last { $0.request.runtime == request.runtime && $0.request.sourceTaskID == request.sourceTaskID }
                ?? records.last { matches($0.request, request) }
        }
    }

    public func changesPublisher() -> AnyPublisher<Void, Never> {
        changes.prepend(()).eraseToAnyPublisher()
    }

    public func start(_ request: TaskContinuationRequest) async -> TaskContinuationAdmission {
        guard !request.conversationID.isEmpty, !request.sourceTaskID.isEmpty,
              hasSourceIdentity(request) else { return .refused(.missingIdentity) }
        let admission = reserve(request)
        guard case .started(let id) = admission else { return admission }
        changes.send(())
        guard actions.tryBeginBusy(request.sourceTaskID) else {
            removeReservation(id)
            return .refused(.busy)
        }
        let outcome: ConversationLaunchOutcome
        do {
            let client = try request.runtime.boundClient(tooling: tooling)
            outcome = await client.continueTask(request.sourceTaskID)
        } catch {
            actions.endBusy(request.sourceTaskID)
            removeReservation(id)
            return .refused(.qualification(QualificationFailure(error: error)))
        }
        actions.endBusy(request.sourceTaskID)
        let changed = lock.withLock {
            guard let index = records.firstIndex(where: { $0.id == id }), records[index].outcome == nil else { return false }
            records[index].outcome = outcome
            return true
        }
        if changed { changes.send(()) }
        return admission
    }

    private func hasSourceIdentity(_ request: TaskContinuationRequest) -> Bool {
        if let loaded = taskList.task(request.sourceTaskID) { return loaded.taskID == request.sourceTaskID }
        return lock.withLock {
            records.contains { $0.request.runtime == request.runtime && $0.permitsRecordedSource(request.sourceTaskID) }
        }
    }

    private func matches(_ lhs: TaskContinuationRequest, _ rhs: TaskContinuationRequest) -> Bool {
        lhs.runtime == rhs.runtime && (lhs.conversationID == rhs.conversationID || lhs.sourceTaskID == rhs.sourceTaskID)
    }

    private func reserve(_ request: TaskContinuationRequest) -> TaskContinuationAdmission {
        lock.withLock {
            let matching = records.filter { matches($0.request, request) }
            if let active = matching.first(where: { $0.outcome == nil }) { return .existing(active.id) }
            let unsafe = matching.filter { record in
                switch record.outcome {
                case .launched?, .uncertain?: true
                default: false
                }
            }
            if let sameSource = unsafe.first(where: { $0.request.sourceTaskID == request.sourceTaskID }) {
                return .existing(sameSource.id)
            }
            if let previous = matching.last, !unsafe.isEmpty, previous.request.sourceTaskID != request.sourceTaskID,
               !previous.permitsRecordedSource(request.sourceTaskID) { return .existing(previous.id) }
            guard records.count < 256 else { return .refused(.capacity) }
            let id = UUID()
            records.append(TaskContinuationAttempt(id: id, request: request, outcome: nil, check: .notChecked))
            return .started(id)
        }
    }

    private func removeReservation(_ id: UUID) {
        let changed = lock.withLock {
            guard let index = records.firstIndex(where: { $0.id == id }), records[index].outcome == nil else { return false }
            records.remove(at: index)
            return true
        }
        if changed { changes.send(()) }
    }

    public func check(attemptID: UUID) async {
        await check(attemptID: attemptID, target: nil)
    }

    public func check(attemptID: UUID, targetSourceTaskID: String) async {
        await check(attemptID: attemptID, target: targetSourceTaskID)
    }

    private func check(attemptID: UUID, target: String?) async {
        let readID = UUID()
        let captured: TaskContinuationAttempt? = lock.withLock {
            guard reads[attemptID] == nil, let index = records.firstIndex(where: { $0.id == attemptID }),
                  records[index].outcome != nil else { return nil }
            let previous = records[index]
            reads[attemptID] = readID
            records[index].check = .checking
            return previous
        }
        guard let captured else { return }
        changes.send(())
        let evidence: TaskContinuationCheck = if let target {
            await TaskContinuationReachability(taskList: taskList, now: now)
                .observe(captured.request, target: target)
        } else {
            await observe(captured.request)
        }
        let changed = lock.withLock {
            guard reads[attemptID] == readID, let index = records.firstIndex(where: { $0.id == attemptID }) else { return false }
            reads.removeValue(forKey: attemptID)
            records[index].check = Task.isCancelled ? captured.check : evidence
            if !Task.isCancelled, case .recorded(let ids) = evidence {
                let combined = Set(records[index].recordedSuccessorTaskIDs + ids)
                if combined.union(records[index].recordedReachableSourceTaskIDs).count <= 400 {
                    records[index].recordedSuccessorTaskIDs = combined.sorted()
                } else {
                    records[index].check = .inconclusive
                }
            }
            if !Task.isCancelled, case .reachable(let source) = evidence {
                let combined = Set(records[index].recordedReachableSourceTaskIDs + [source])
                if combined.union(records[index].recordedSuccessorTaskIDs).count <= 400 {
                    records[index].recordedReachableSourceTaskIDs = combined.sorted()
                } else {
                    records[index].check = .inconclusive
                }
            }
            return true
        }
        if changed { changes.send(()) }
    }

    private func observe(_ request: TaskContinuationRequest) async -> TaskContinuationCheck {
        let deadline = now().advanced(by: .seconds(120))
        var cursor: String?
        var cursors = Set<String>()
        var identifiers = Set<String>()
        var rowCount = 0
        for _ in 0 ..< 4 {
            guard !Task.isCancelled, now() < deadline else { return .inconclusive }
            do {
                let page = try await taskList.successorPage(predecessorTaskID: request.sourceTaskID, cursor: cursor, runtime: request.runtime)
                guard !Task.isCancelled, now() < deadline, page.predecessorTaskID == request.sourceTaskID else { return .inconclusive }
                let history = page.history.page
                rowCount += history.items.count + history.relatedHeaders.count
                guard rowCount <= 400, !page.readinessUnknown, history.catalogState.isReady,
                      !history.bootstrapPending, !history.historyIncomplete, !history.authorityIncomplete else { return .inconclusive }
                for item in page.history.items {
                    guard item.taskID != request.sourceTaskID, identifiers.insert(item.taskID).inserted,
                          item.parentTaskID == request.sourceTaskID || item.raw["continuation_of_task_id"]?.stringValue == request.sourceTaskID else {
                        return .inconclusive
                    }
                }
                if !history.hasMore { return .recorded(successorTaskIDs: identifiers.sorted()) }
                guard let next = history.nextCursor, next != cursor, cursors.insert(next).inserted else { return .inconclusive }
                cursor = next
            } catch {
                return .failed(QualificationFailure(error: error))
            }
        }
        return .inconclusive
    }
}
