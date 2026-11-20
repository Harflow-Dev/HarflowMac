import Foundation

// MARK: - WorkflowSteeringFailure

/// Failure evidence retains structured details without treating generic engine errors as refusals.
public struct WorkflowSteeringFailure: Equatable, Sendable {
    public let error: ToolError
    public let structuredCode: String?
    /// A validated nonzero structured response from a command positively known to have exited.
    public let definiteExit: Bool
    /// The selected immutable managed generation matches the audited bundled producer.
    public let auditedProducer: Bool
    /// The complete bounded structured error object, preserving exact raw JSON values.
    public let rawError: Data?

    /// A public receipt reference contradicts treating an error as proof of nonadmission.
    public var hasReceiptReference: Bool {
        guard let rawError, let object = WorkflowSteeringWire.object(rawError),
              let detail = object["data"] as? [String: Any], let reference = detail["receipt_ref"] else { return false }
        return !(reference is NSNull)
    }
}

// MARK: - WorkflowSteeringOutcome

/// One invocation's phase-aware evidence; no case authorizes replay.
public enum WorkflowSteeringOutcome: Equatable, Sendable {
    case admitted(WorkflowSteeringReceipt)
    case notDispatched(ToolError)
    case refused(WorkflowSteeringFailure)
    case indeterminate(WorkflowSteeringFailure)
}

// MARK: - CtlClient workflow steering

public extension CtlClient {
    /// Reads exact-root steering status after a fresh paired-capability handshake.
    func workflowSteeringStatus(rootID: String) async -> Result<WorkflowSteeringStatus, ToolError> {
        await steeringRead(command: "workflow-steering-status", rootID: rootID, options: []).flatMap { data in
            guard let status = WorkflowSteeringStatus(data: data, rootID: rootID, productVersion: compatibilityContext.productVersion) else {
                return .failure(WorkflowSteeringWire.error("Malformed root steering status"))
            }
            return .success(status)
        }
    }

    /// Reads one bounded page; the caller owns traversal and its independent limits.
    func workflowSteeringHistory(rootID: String, cursor: String? = nil) async -> Result<WorkflowSteeringHistoryPage, ToolError> {
        guard cursor.map({ $0.utf8.count <= 4096 && WorkflowSteeringWire.cursorSequence($0, rootID: rootID) != nil }) ?? true else {
            return .failure(WorkflowSteeringWire.error("Invalid steering history cursor"))
        }
        let options = ["--limit=50"] + (cursor.map { ["--cursor=\($0)"] } ?? [])
        return await steeringRead(command: "workflow-steering-history", rootID: rootID, options: options).flatMap { data in
            let after = cursor.flatMap { WorkflowSteeringWire.cursorSequence($0, rootID: rootID) } ?? 0
            guard let page = WorkflowSteeringHistoryPage(data: data, rootID: rootID, productVersion: compatibilityContext.productVersion),
                  page.items.allSatisfy({ $0.sequence > after }),
                  !page.hasMore || page.items.last.map({ $0.sequence > after }) == true else {
                return .failure(WorkflowSteeringWire.error("Malformed root steering history"))
            }
            return .success(page)
        }
    }

    /// Sends one immutable action with private input and never retries it.
    func workflowSteer(_ request: WorkflowSteeringRequest) async -> WorkflowSteeringOutcome {
        guard operationIsCurrent(), !Task.isCancelled else {
            return .notDispatched(WorkflowSteeringWire.error("Steering operation superseded before launch"))
        }
        let input: PrivateJSONInput
        do {
            input = try PrivateJSONInput(data: request.data, filename: "request.json", baseDirectory: environment["TMPDIR"])
        } catch {
            return .notDispatched(WorkflowSteeringWire.error("Unable to create private steering input"))
        }
        defer { input.cleanUp() }
        let exchange = await conversationExchange(command: "workflow-steer", options: ["--monitor", "--request-file=\(input.file.path)"],
                                                  positionals: [request.status.rootID], timeout: Self.conversationMutationTimeout,
                                                  requiredCapabilities: Self.steeringCapabilities)
        switch exchange {
        case .notLaunched(let cause): return .notDispatched(Self.toolError(for: cause, command: "workflow-steer"))
        case .launched(.failure(let error)):
            if case .launchFailed = error { return .notDispatched(error) }
            return .indeterminate(steeringFailure(error))
        case .launched(.success(let output)): return classifySteering(output, request: request)
        }
    }

    /// Exact bundled provenance plus selected generation identity; version compatibility alone is insufficient.
    var isAuditedSteeringProducer: Bool {
        guard let specification = try? ManagedRuntimeSpecification.bundled(),
              specification.engineVersion == "0.0.14",
              specification.provenance.hasPrefix("HarflowMCP v0.0.14 commit a891388b1259add2ec8432d7d0fc5ca38163c27d;"),
              let home = environment["HOME"], let normalized = LexicalStateRoot.normalize(home),
              compatibilityContext.expectedStateRoot == ManagedRuntimeLayout(home: normalized).stateRoot else { return false }
        let prefix = ManagedRuntimeLayout(home: normalized).generationsDirectory + "/0.0.14-" + specification.identity + "-"
        let suffix = "/bin/harflow-ctl"
        guard executable.hasPrefix(prefix), executable.hasSuffix(suffix) else { return false }
        let generation = String(executable.dropFirst(prefix.count).dropLast(suffix.count))
        return UUID(uuidString: generation) != nil
    }
}

extension CtlClient {
    private static let steeringCapabilities = ["workflow-steering-read.v1", "workflow-steering-orchestrator.v1"]

    private func steeringRead(command: String, rootID: String, options: [String]) async -> Result<Data, ToolError> {
        guard WorkflowSteeringWire.identifier(rootID) else { return .failure(WorkflowSteeringWire.error("Invalid full root run ID")) }
        let exchange = await conversationExchange(command: command, options: ["--monitor"] + options, positionals: [rootID],
                                                  timeout: Self.quickTimeout, requiredCapabilities: Self.steeringCapabilities)
        let output: ProcessOutput
        switch exchange {
        case .notLaunched(let cause): return .failure(Self.toolError(for: cause, command: command))
        case .launched(.failure(let error)): return .failure(error)
        case .launched(.success(let value)): output = value
        }
        guard operationIsCurrent(), !Task.isCancelled else {
            return .failure(WorkflowSteeringWire.error("Steering read superseded after response"))
        }
        guard !output.timedOut, output.exitCode == 0,
              let document = WorkflowSteeringWire.envelope(output.stdout, productVersion: compatibilityContext.productVersion),
              document["result"] is [String: Any] else {
            if let failure = structuredSteeringFailure(output) { return .failure(failure.error) }
            return .failure(WorkflowSteeringWire.error("Unavailable or malformed steering read"))
        }
        return .success(output.stdout)
    }

    private func steeringFailure(_ error: ToolError) -> WorkflowSteeringFailure {
        WorkflowSteeringFailure(error: error, structuredCode: nil, definiteExit: false,
                                auditedProducer: false, rawError: nil)
    }

    private func structuredSteeringFailure(_ output: ProcessOutput) -> WorkflowSteeringFailure? {
        guard !output.timedOut, output.exitCode > 0,
              let document = WorkflowSteeringWire.envelope(output.stdout, productVersion: compatibilityContext.productVersion),
              let object = document["error"] as? [String: Any],
              let code = object["code"] as? String, !code.isEmpty,
              let message = object["message"] as? String,
              let raw = WorkflowSteeringWire.canonical(object) else { return nil }
        if let detail = object["data"], !(detail is [String: Any]) { return nil }
        let detail = (CtlDocument.firstJSONObject(in: output.stdout)?["error"]?.objectValue)?["data"]?.objectValue
        let error: ToolError = detail.map { .structuredRefusal(code: code, message: message, data: $0) }
            ?? .refused(code: code, message: message)
        let audited = isAuditedSteeringProducer && document["product_version"] as? String == "0.0.14"
        return WorkflowSteeringFailure(error: error, structuredCode: code, definiteExit: !Task.isCancelled, auditedProducer: audited, rawError: raw)
    }

    private func classifySteering(_ output: ProcessOutput, request: WorkflowSteeringRequest) -> WorkflowSteeringOutcome {
        guard !output.timedOut else {
            return .indeterminate(steeringFailure(.timedOut(tool: "harflow-ctl", seconds: Self.conversationMutationTimeout)))
        }
        if output.exitCode == 0,
           let receipt = WorkflowSteeringReceipt(data: output.stdout, matching: request, productVersion: compatibilityContext.productVersion) {
            return .admitted(receipt)
        }
        if let failure = structuredSteeringFailure(output) {
            let preadmission = ["interaction_revoked", "steering_revision_stale", "steering_target_stale", "request_expired", "steering_budget_exhausted"]
            if failure.definiteExit, failure.auditedProducer, !failure.hasReceiptReference,
               let code = failure.structuredCode, preadmission.contains(code) {
                return .refused(failure)
            }
            return .indeterminate(failure)
        }
        return .indeterminate(steeringFailure(WorkflowSteeringWire.error("Missing or inconsistent steering admission receipt")))
    }
}
