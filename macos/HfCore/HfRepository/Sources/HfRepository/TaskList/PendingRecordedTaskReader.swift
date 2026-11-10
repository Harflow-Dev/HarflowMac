import Foundation
import MonitorCore

// MARK: - PendingRecordedTaskReader

enum PendingRecordedTaskReader {
    static func sorted(_ tasks: [TaskInfo]) -> [TaskInfo] {
        tasks.sorted {
            let lhs = $0.startedAt ?? .distantPast
            let rhs = $1.startedAt ?? .distantPast
            return lhs == rhs ? $0.taskID > $1.taskID : lhs > rhs
        }
    }

    /// Reads the target and its actual conversation chain before admitting anything. All rows
    /// are fresh in the same runtime; unrelated spawned-by tasks never become conversation parents.
    static func readAncestry(_ id: String, runtime: QualificationRuntimeToken, tooling: any ToolEnvironmentRepository,
                             gate: PendingLaunchAdmissionGate, now: @Sendable () -> ContinuousClock.Instant) async throws -> [TaskInfo] {
        let start = now()
        var client = try runtime.boundClient(tooling: tooling)
        let original = client.operationIsCurrent
        client.operationIsCurrent = { gate.isCurrent && original() }
        var target: String? = id
        var visited: Set<String> = []
        var rows: [TaskInfo] = []
        var bytes = 0
        while let current = target {
            try requireCurrent(client, gate: gate)
            guard now() - start < .seconds(120) else { throw PendingRecordedAdmissionFailure.deadline }
            guard rows.count < 32 else { throw PendingRecordedAdmissionFailure.requestBudget }
            guard TaskPendingLaunchWire.isFullID(current) else { throw PendingRecordedAdmissionFailure.unqualified(taskID: current) }
            guard visited.insert(current).inserted else { throw PendingRecordedAdmissionFailure.cycle }
            let result = await client.status(current)
            try requireCurrent(client, gate: gate)
            _ = try runtime.boundClient(tooling: tooling)
            guard now() - start < .seconds(120) else { throw PendingRecordedAdmissionFailure.deadline }
            let item: TaskInfo
            switch result {
            case .success(let value): item = value
            case .failure(let error): throw PendingRecordedAdmissionFailure.ancestorRead(taskID: current, error: error)
            }
            try qualify(item, requestedID: current)
            bytes += JSONValue.object(item.raw).rendered().utf8.count
            guard bytes <= 8 * 1024 * 1024 else { throw PendingRecordedAdmissionFailure.responseBudget }
            rows.append(item)
            target = item.continuationOfTaskID ?? item.parentTaskID
        }
        guard let root = rows.last, Lineage.conversationID(of: id, in: rows) == root.taskID else {
            throw PendingRecordedAdmissionFailure.unqualified(taskID: id)
        }
        return rows
    }

    private static func requireCurrent(_ client: CtlClient, gate: PendingLaunchAdmissionGate) throws {
        guard gate.isCurrent, client.operationIsCurrent(), !Task.isCancelled else { throw QualificationSessionError.runtimeChanged }
    }

    private static func qualify(_ item: TaskInfo, requestedID: String) throws {
        guard item.taskID == requestedID, item.raw["status"]?.stringValue != nil,
              item.status.isRunning || item.status.isTerminal else { throw PendingRecordedAdmissionFailure.unqualified(taskID: requestedID) }
        for key in ["continuation_of_task_id", "parent_task_id"] {
            if let raw = item.raw[key], raw != .null {
                guard let id = raw.stringValue, TaskPendingLaunchWire.isFullID(id) else {
                    throw PendingRecordedAdmissionFailure.unqualified(taskID: requestedID)
                }
            }
        }
    }

    /// Keeps existing legacy callers' cache/ancestry behavior unchanged and separate from admission.
    static func legacyResolve(_ id: String, client: CtlClient, cached: @Sendable (String) -> TaskInfo?) async -> [TaskInfo] {
        var current: String? = id
        var visited: Set<String> = []
        var resolved: [TaskInfo] = []
        while let target = current, visited.count < 32, visited.insert(target).inserted {
            let fetched: TaskInfo? = if target != id, let existing = cached(target) { existing } else { try? await client.status(target).get() }
            guard let item = fetched else { break }
            resolved.append(item)
            current = item.parentTaskID ?? item.spawnedBy
        }
        return resolved
    }
}
