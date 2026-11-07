import MonitorCore

// MARK: - TaskChangesRepositoryImpl

/// Stateless reads bound to the captured selected runtime and the caller's lifetime fence.
public struct TaskChangesRepositoryImpl: TaskChangesRepository {
    private let toolEnvironment: any ToolEnvironmentRepository
    private let stateRecovery: any StateRecoveryRepository
    private let now: @Sendable () -> ContinuousClock.Instant

    public init(toolEnvironment: any ToolEnvironmentRepository, recovery: any StateRecoveryRepository,
                now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.toolEnvironment = toolEnvironment
        self.stateRecovery = recovery
        self.now = now
    }

    public func readListing(key: TaskChangesKey, operationIsCurrent: @escaping @Sendable () -> Bool)
        async -> Result<TaskChangesRead<TaskChangesSnapshot>, TaskChangesReadFailure> {
        await fenced(key, operationIsCurrent) { client, budget in
            await Self.listing(client: client, key: key, budget: budget)
        }
    }

    public func readPatch(key: TaskChangesKey, selector: TaskChangesSelector, operationIsCurrent: @escaping @Sendable () -> Bool)
        async -> Result<TaskChangesRead<TaskChangesPatch>, TaskChangesReadFailure> {
        await fenced(key, operationIsCurrent) { client, budget in
            await Self.patch(client: client, key: key, selector: selector, budget: budget)
        }
    }

    // MARK: Fence

    private func fenced<Value: Equatable & Sendable>(
        _ key: TaskChangesKey,
        _ operationIsCurrent: @escaping @Sendable () -> Bool,
        _ body: (CtlClient, ReadBudget) async -> Result<TaskChangesRead<Value>, TaskChangesReadFailure>
    ) async -> Result<TaskChangesRead<Value>, TaskChangesReadFailure> {
        let superseded = TaskChangesReadFailure(key: key, outcome: .superseded)
        guard !Task.isCancelled, operationIsCurrent() else { return .failure(superseded) }
        let captured: CtlClient
        switch toolEnvironment.ctl() {
        case .success(let client): captured = client
        case .failure(let error):
            guard !Task.isCancelled, operationIsCurrent() else { return .failure(superseded) }
            stateRecovery.report(error)
            return .failure(TaskChangesReadFailure(key: key, outcome: .failed(error)))
        }
        let tooling = toolEnvironment
        let isCurrent: @Sendable () -> Bool = {
            guard !Task.isCancelled, captured.operationIsCurrent(), operationIsCurrent(),
                  case .success(let current) = tooling.ctl() else { return false }
            return current.executable == captured.executable
                && current.environment == captured.environment
                && current.compatibilityContext == captured.compatibilityContext
        }
        var client = captured
        client.operationIsCurrent = isCurrent
        guard isCurrent() else { return .failure(superseded) }
        let budget = ReadBudget(key: key, isCurrent: isCurrent, now: now)
        let response = await body(client, budget)
        guard isCurrent() else { return .failure(superseded) }
        if case .failure(let failure) = response, case .failed(let error) = failure.outcome { stateRecovery.report(error) }
        return response
    }

    // MARK: Listing

    private static func listing(client: CtlClient, key: TaskChangesKey,
                                budget: ReadBudget) async -> Result<TaskChangesRead<TaskChangesSnapshot>, TaskChangesReadFailure> {
        var budget = budget
        var restarts = 0
        while true {
            var builder = TaskChangesListingBuilder()
            var cursor: String?
            var expired = false
            repeat {
                if let failure = budget.admit() { return .failure(failure) }
                let response = await client.taskChangesPage(taskID: key.taskID, limit: TaskChangesLimits.maxPageLimit, cursor: cursor)
                switch response {
                case .failure(let error):
                    guard error.isTaskChangesCursorExpired, cursor != nil, restarts < TaskChangesLimits.maxRestarts else {
                        return .failure(budget.failure(error))
                    }
                    expired = true
                case .success(let page):
                    do { try builder.append(page) } catch { return .failure(budget.malformed(error)) }
                    cursor = builder.nextCursor
                }
            } while !expired && !builder.isFinished
            if expired {
                restarts += 1
                continue
            }
            do { return .success(TaskChangesRead(key: key, value: try builder.finish())) } catch { return .failure(budget.malformed(error)) }
        }
    }

    // MARK: Patch

    private static func patch(client: CtlClient, key: TaskChangesKey, selector: TaskChangesSelector,
                              budget: ReadBudget) async -> Result<TaskChangesRead<TaskChangesPatch>, TaskChangesReadFailure> {
        var budget = budget
        var restarts = 0
        while true {
            var assembler = TaskChangesTextAssembler(selector: selector)
            var cursor: String?
            var expired = false
            var finished = false
            repeat {
                if let failure = budget.admit() { return .failure(failure) }
                let response: Result<TaskChangesTextChunk, ToolError> = if let cursor {
                    await client.taskChangesTextChunk(taskID: key.taskID, cursor: cursor)
                } else {
                    await client.taskChangesTextChunk(taskID: key.taskID, selector: selector)
                }
                switch response {
                case .failure(let error):
                    guard error.isTaskChangesCursorExpired, cursor != nil, restarts < TaskChangesLimits.maxRestarts else {
                        return .failure(budget.failure(error))
                    }
                    expired = true
                case .success(let chunk):
                    do { try assembler.append(chunk) } catch { return .failure(budget.malformed(error)) }
                    cursor = assembler.nextCursor
                    finished = cursor == nil
                }
            } while !expired && !finished
            if expired {
                restarts += 1
                continue
            }
            do { return .success(TaskChangesRead(key: key, value: try assembler.finish())) } catch { return .failure(budget.malformed(error)) }
        }
    }
}

// MARK: - ReadBudget

/// Work allowed for one read across restarts: a request count and a wall-clock deadline, both checked
/// before each request together with the caller's fence.
private struct ReadBudget {
    let key: TaskChangesKey
    let isCurrent: @Sendable () -> Bool
    private let deadline: ContinuousClock.Instant
    private let now: @Sendable () -> ContinuousClock.Instant
    private var requests = 0

    init(key: TaskChangesKey, isCurrent: @escaping @Sendable () -> Bool, now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.key = key
        self.isCurrent = isCurrent
        self.now = now
        self.deadline = now().advanced(by: .seconds(TaskChangesLimits.maxReadSeconds))
    }

    /// `nil` when one more request is allowed.
    mutating func admit() -> TaskChangesReadFailure? {
        guard isCurrent() else { return TaskChangesReadFailure(key: key, outcome: .superseded) }
        guard now() < deadline else {
            return failure(.timedOut(tool: "harflow-ctl task-changes", seconds: Double(TaskChangesLimits.maxReadSeconds)))
        }
        guard requests < TaskChangesLimits.maxRequestsPerRead else {
            return failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "task-changes read exceeded its request budget"))
        }
        requests += 1
        return nil
    }

    /// A tool error, or a supersession when the fence no longer holds.
    func failure(_ error: ToolError) -> TaskChangesReadFailure {
        TaskChangesReadFailure(key: key, outcome: isCurrent() ? .failed(error) : .superseded)
    }

    func malformed(_ error: Error) -> TaskChangesReadFailure {
        let detail = (error as? TaskChangesAssemblyError)?.message ?? "task-changes read inconsistent"
        return failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: detail))
    }
}
