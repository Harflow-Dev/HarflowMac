import Foundation

// MARK: - CtlClient pending-launch reads

public extension CtlClient {
    /// Reads exactly one page through a fresh capability probe; no traversal or cache is owned here.
    func taskPendingPage(limit: Int = 50, cursor: String? = nil) async -> Result<TaskPendingLaunchPage, ToolError> {
        guard (1 ... 100).contains(limit), cursor.map({ !$0.isEmpty && $0.utf8.count <= TaskPendingLaunchWire.maximumCursorBytes }) ?? true else {
            return .failure(Self.pendingMalformed("Invalid pending page request"))
        }
        var options = ["--limit=\(limit)"]
        if let cursor { options.append("--cursor=\(cursor)") }
        return await pendingRead("task-pending-page", options: options).flatMap {
            guard let page = TaskPendingLaunchPage(raw: $0, requestedLimit: limit) else {
                return .failure(Self.pendingMalformed("Malformed pending page"))
            }
            return .success(page)
        }
    }

    /// Reads an unchanged exact full ID. Missing evidence never proves no-spawn or safe replay.
    func taskPendingStatus(taskID: String) async -> Result<TaskPendingLaunchLookup, ToolError> {
        guard TaskPendingLaunchWire.isFullID(taskID) else {
            return .failure(Self.pendingMalformed("Invalid full pending task ID"))
        }
        return await pendingRead("task-pending-status", options: ["--task-id=\(taskID)"]).flatMap {
            guard let lookup = TaskPendingLaunchLookup(raw: $0, requestedTaskID: taskID) else {
                return .failure(Self.pendingMalformed("Malformed pending lookup or mismatched identity"))
            }
            return .success(lookup)
        }
    }

    /// Requests ordinary full-ID cancel, including a possible same-ID spawn race. No generation
    /// precondition or automatic retry exists. Acknowledgement alone does not mean stopped.
    func stopPendingLaunch(_ request: TaskPendingLaunchStopRequest) async -> TaskPendingLaunchStopOutcome {
        let exchange = await conversationExchange(command: "cancel", options: [], positionals: [request.taskID],
                                                  timeout: Self.takeoverTimeout,
                                                  requiredCapabilities: [CtlCapability.taskPendingLaunch, CtlCapability.taskCancelCascade])
        switch exchange {
        case .notLaunched(let cause): return .notDispatched(request, cause: cause)
        case .launched(let output):
            return classifyConversationMutation(output, command: "cancel", options: [], request: request,
                                                timeout: Self.takeoverTimeout) {
                TaskPendingLaunchStopReceipt(raw: $0, matching: request)
            }
        }
    }
}

extension CtlClient {
    static func pendingMalformed(_ message: String) -> ToolError {
        .unreadable(tool: "harflow-ctl", exitCode: 0, stderr: message)
    }

    private func pendingRead(_ command: String, options: [String]) async -> Result<[String: JSONValue], ToolError> {
        let exchange = await conversationExchange(command: command, options: options, positionals: [],
                                                  timeout: Self.quickTimeout, requiredCapabilities: [CtlCapability.taskPendingLaunch])
        let output: ProcessOutput
        switch exchange {
        case .notLaunched(let cause): return .failure(Self.toolError(for: cause, command: command))
        case .launched(.failure(let error)): return .failure(error)
        case .launched(.success(let value)): output = value
        }
        // Must precede validateTransportOutput, which itself parses JSON.
        guard output.stdout.count <= TaskPendingLaunchWire.maximumDocumentBytes else {
            return .failure(Self.pendingMalformed("Pending document exceeded byte limit"))
        }
        guard operationIsCurrent(), !Task.isCancelled else {
            return .failure(WireEnvelope.incompatibility("pending read superseded after response"))
        }
        if let document = CtlDocument.firstJSONObject(in: output.stdout) {
            let payloads = ["result", "error", "unknown"].filter { document[$0] != nil }
            guard payloads.count == 1,
                  (payloads[0] == "result" && output.exitCode == 0) ||
                  (payloads[0] == "error" && output.exitCode != 0) else {
                return .failure(Self.pendingMalformed("Inconsistent pending read envelope"))
            }
        }
        return validateTransportOutput(output, command: command, options: options, timeout: Self.quickTimeout)
.flatMap { output in
            CtlDocument.decode(stdout: output.stdout, stderr: output.stderr, exitCode: output.exitCode,
                               command: command, productVersion: compatibilityContext.productVersion)
        }
.requiringSuccess()
.flatMap { document in
            guard case .result(let raw) = document else { return .failure(Self.pendingMalformed("Missing pending result")) }
            return .success(raw)
        }
    }
}

// MARK: - TaskPendingLaunchStopRequest

/// Exact target only. Inventory generation and mechanism support confer no mutation authority.
public struct TaskPendingLaunchStopRequest: Equatable, Sendable {
    public let taskID: String

    public init?(taskID: String) {
        guard TaskPendingLaunchWire.isFullID(taskID) else { return nil }
        self.taskID = taskID
    }
}

// MARK: - TaskPendingLaunchStopReceipt

/// Capability-qualified acknowledgement with the raw cascade retained for diagnostics.
/// Corrupt/missing observations refuse receipt admission and become uncertain after dispatch.
public struct TaskPendingLaunchStopReceipt: Equatable, Sendable {
    public let taskID: String
    public let observation: CancelCascadeObservation
    public let raw: [String: JSONValue]

    init?(raw: [String: JSONValue], matching request: TaskPendingLaunchStopRequest) {
        guard raw["task_id"]?.stringValue == request.taskID,
              case .present(let observation) = CancelCascadeObservation.reading(in: raw),
              observation.scope == "recorded_tasks_and_pending_launches",
              observation.items.allSatisfy({ TaskPendingLaunchWire.isFullID($0.taskID) }),
              Set(observation.items.map(\.taskID)).count == observation.items.count else { return nil }
        self.taskID = request.taskID
        self.observation = observation
        self.raw = raw
    }

    /// Stronger evidence than stopped: the qualified target never started. Settlement of a
    /// process that ran does not satisfy this predicate.
    public var targetIsProvenNotStarted: Bool {
        targetIsProvenStopped && observation.items.first(where: { $0.taskID == taskID })?.basis == .provenNotStarted
    }

    /// Only positive qualified target evidence establishes stopped; status strings and absent
    /// rows never do. Unknown coverage, omitted rows or contradictory bases retain uncertainty.
    public var targetIsProvenStopped: Bool {
        guard observation.coverage == .complete, !observation.truncated,
              let target = observation.items.first(where: { $0.taskID == taskID }), target.state == .stopped else { return false }
        return target.basis == .observedSettlement || target.basis == .provenNotStarted
    }
}

/// Phase-aware evidence for one cancel invocation; engine errors do not prove no side effect.
public typealias TaskPendingLaunchStopOutcome = ConversationDeliveryOutcome<TaskPendingLaunchStopRequest, TaskPendingLaunchStopReceipt>
