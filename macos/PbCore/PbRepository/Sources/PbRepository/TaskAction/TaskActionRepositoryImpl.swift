import Combine
import Foundation
import MonitorCore
import PbUtilities

// MARK: - TaskActionRepositoryImpl

public final class TaskActionRepositoryImpl: TaskActionRepository, @unchecked Sendable {

    private let toolEnvironment: any ToolEnvironmentRepository
    private let taskListRepository: any TaskListRepository
    private let snapshotRepository: any TaskSnapshotRepository

    @Subjected private var busyValue: Set<String> = []
    @Subjected private var outcomesValue: [String: String] = [:]
    private let outcomeLock = NSLock()
    private let busyLock = NSRecursiveLock()

    /// `TaskActionRepository → TaskListRepository + TaskSnapshotRepository` (decision 6): an
    /// accepted action refreshes both.
    public init(
        toolEnvironment: any ToolEnvironmentRepository,
        taskListRepository: any TaskListRepository,
        snapshotRepository: any TaskSnapshotRepository
    ) {
        self.toolEnvironment = toolEnvironment
        self.taskListRepository = taskListRepository
        self.snapshotRepository = snapshotRepository
    }

    public var busy: Set<String> { busyValue }
    public func busyPublisher() -> AnyPublisher<Set<String>, Never> { $busyValue.eraseToAnyPublisher() }
    public func outcome(_ taskID: String) -> String? { outcomesValue[taskID] }
    public func outcomesPublisher() -> AnyPublisher<[String: String], Never> { $outcomesValue.eraseToAnyPublisher() }

    @discardableResult
    public func tryBeginBusy(_ taskID: String) -> Bool {
        busyLock.lock(); defer { busyLock.unlock() }
        if busyValue.contains(taskID) { return false }
        busyValue.insert(taskID)
        return true
    }

    public func endBusy(_ taskID: String) {
        busyLock.lock(); defer { busyLock.unlock() }
        busyValue.remove(taskID)
    }

    private func isBusy(_ taskID: String) -> Bool {
        busyLock.lock(); defer { busyLock.unlock() }
        return busyValue.contains(taskID)
    }

    /// Locked because outcomes are written from the main actor (TakeoverService) and from the
    /// background tasks running cancel/send/resume; `@Subjected` alone makes only each get or set atomic.
    public func setOutcome(_ taskID: String, _ text: String?) {
        outcomeLock.lock()
        defer { outcomeLock.unlock() }
        var current = outcomesValue
        current[taskID] = text
        outcomesValue = current
    }

    // MARK: perform (AppModel.swift:254-269 = F4-14/MS-ACTIONS-1)

    /// A locator failure never enters busy; on completion busy is cleared, then the outcome is
    /// written, then the listing refreshes, then the snapshot refreshes — in that order
    /// (`AppModel.swift:254-267`). The outcome is always written before this can throw, so it
    /// survives even if nobody is left to catch the error.
    ///
    /// - Returns: `true` if the command was attempted (whatever its own result), `false` if
    ///   `taskID` was already busy — in which case nothing here runs and nothing is thrown.
    /// - Throws: the `ToolError` behind a locator failure or the command's own refusal, *after* the
    ///   outcome and both refreshes.
    private func perform(_ taskID: String, _ work: @escaping @Sendable (CtlClient) async -> Result<String, ToolError>) async throws -> Bool {
        guard !isBusy(taskID) else { return false }
        switch toolEnvironment.ctl() {
        case .failure(let error):
            setOutcome(taskID, error.message)
            throw error
        case .success(let client):
            guard tryBeginBusy(taskID) else { return false }
            let result = await work(client)
            endBusy(taskID)
            let message: String = switch result {
            case .success(let value): value
            case .failure(let error): error.message
            }
            setOutcome(taskID, message)
            await taskListRepository.refresh()
            await snapshotRepository.refresh(taskID)
            if case .failure(let error) = result { throw error }
            return true
        }
    }

    @discardableResult
    public func cancel(_ taskID: String) async throws -> Bool {
        try await perform(taskID) { client in
            switch await client.cancel(taskID) {
            case .success(let result): .success(CascadeSummary.describe(result))
            case .failure(let error): .failure(error)
            }
        }
    }

    public func cancelAll(_ ids: [String]) async {
        // Each member's own `perform` already wrote its outcome before any error could surface here;
        // `try?` only discards the *rethrow*, so one member's failure never stops the others from
        // being attempted (F4-15).
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { _ = try? await self.cancel(id) }
            }
        }
    }

    @discardableResult
    public func send(_ taskID: String, text: String) async throws -> Bool {
        try await perform(taskID) { client in
            switch await client.send(taskID, text: text) {
            case .success: .success("Queued — not yet delivered. The timeline shows it once the agent receives it.")
            case .failure(let error): .failure(error)
            }
        }
    }

    @discardableResult
    public func resume(_ taskID: String, text: String, onResumed: @escaping @Sendable (String) async -> Void) async throws -> String? {
        guard !isBusy(taskID) else { return nil }
        switch toolEnvironment.ctl() {
        case .failure(let error):
            setOutcome(taskID, error.message)
            throw error
        case .success(let client):
            guard tryBeginBusy(taskID) else { return nil }
            let result = await client.resume(taskID, text: text)
            let newID: String?
            let message: String
            switch result {
            case .success(let id):
                newID = id
                message = "Continued as task \(id.prefix(8))."
                // Fires before `endBusy`/the outcome write/both refreshes — see the protocol doc.
                await onResumed(id)
            case .failure(let error):
                newID = nil
                message = error.message
            }
            endBusy(taskID)
            setOutcome(taskID, message)
            await taskListRepository.refresh()
            await snapshotRepository.refresh(taskID)
            if case .failure(let error) = result { throw error }
            return newID
        }
    }

    // MARK: run (F4-17 — refreshes before returning; errors go to the caller, never the outcome line)

    public func run(_ request: RunRequest) async throws -> String {
        switch toolEnvironment.ctl() {
        case .failure(let error):
            throw error
        case .success(let client):
            switch await client.run(request) {
            case .success(let id):
                await taskListRepository.refresh()
                return id
            case .failure(let error):
                throw error
            }
        }
    }

    // MARK: takeover (raw — touches neither busy nor outcome; PbTerminal.TakeoverService owns that)

    /// Takes the caller's already-located `client` rather than re-locating one (see the protocol
    /// doc) — the grant and the later attach must agree on the same `CtlClient`.
    public func takeover(_ taskID: String, using client: CtlClient) async throws -> TakeoverGrant {
        switch await client.takeover(taskID) {
        case .success(let grant): return grant
        case .failure(let error): throw error
        }
    }

    public func takeoverAttach(_ taskID: String, pid: Int32, using client: CtlClient) async throws {
        switch await client.takeoverAttach(taskID, pid: pid) {
        case .success: return
        case .failure(let error): throw error
        }
    }
}
