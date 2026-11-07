import Foundation

// MARK: - ConversationDeliveryInputFile

/// Keeps a request document private for its entire temporary lifetime: a 0700 directory and a
/// 0600 file. This is a disposable input, not a state file.
struct ConversationDeliveryInputFile {
    let file: URL
    private let directory: URL

    /// `baseDirectory` is an internal seam so a test can force a creation failure.
    init(body: Data, baseDirectory: URL = FileManager.default.temporaryDirectory) throws {
        let manager = FileManager.default
        let directory = baseDirectory
            .appendingPathComponent("harflow-conversation-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("request.json")
        guard manager.createFile(atPath: file.path, contents: body, attributes: [.posixPermissions: 0o600]) else {
            try? manager.removeItem(at: directory)
            throw CocoaError(.fileWriteUnknown)
        }
        self.directory = directory
        self.file = file
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - ConversationExchange

/// The phase an invocation reached. Classification depends on this, never on the error case alone.
enum ConversationExchange {
    /// No command was launched; the cause is positive evidence.
    case notLaunched(ConversationDeliveryNotDispatchedCause)
    /// The runner was invoked; anything the command may have done is possible.
    case launched(Result<ProcessOutput, ToolError>)
}

// MARK: - CtlClient conversation delivery

public extension CtlClient {
    /// Reads a task's conversation projection through a fresh capability handshake. Prepare
    /// dispatches no response, so plain failures suffice.
    ///
    /// Prepare does not enroll a standalone task: a task launched without a conversation profile is
    /// refused for real backends. Enrollment of a standalone task happens at launch, through
    /// ``conversationLaunch(_:profile:)`` or ``conversationResume(taskID:text:profile:maxTurns:)``. Only a
    /// workflow-owned target can be bound by prepare. A failed prepare leaves any earlier uncertain
    /// state uncertain.
    func conversationPrepare(taskID: String) async -> Result<ConversationDeliveryProjection, ToolError> {
        guard ConversationDeliveryWire.isIdentifier(taskID) else {
            return .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "conversation-prepare task id is invalid"))
        }
        let exchange = await conversationExchange(command: "conversation-prepare", options: ["--monitor"],
                                                  positionals: [taskID], timeout: Self.conversationPrepareTimeout)
        let decoded: Result<CtlDocument, ToolError>
        switch exchange {
        case .notLaunched(let cause):
            decoded = .failure(Self.toolError(for: cause, command: "conversation-prepare"))
        case .launched(.failure(let error)):
            decoded = .failure(error)
        case .launched(.success(let output)):
            // The size check precedes every parse, including the one in transport validation.
            if output.timedOut {
                decoded = .failure(.timedOut(tool: "harflow-ctl conversation-prepare", seconds: Self.conversationPrepareTimeout))
            } else if output.stdout.count > Self.conversationReadStdoutCap {
                decoded = .failure(.unreadable(tool: "harflow-ctl", exitCode: output.exitCode,
                                               stderr: "conversation-prepare exceeded document byte limit"))
            } else {
                decoded = validateTransportOutput(output, command: "conversation-prepare", options: ["--monitor"],
                                                  timeout: Self.conversationPrepareTimeout).flatMap { output in
                    let decodeStart = MonitorMetrics.begin()
                    defer { MonitorMetrics.end(decodeStart, stage: .decode, bytes: output.stdout.count) }
                    return CtlDocument.decode(stdout: output.stdout, stderr: output.stderr, exitCode: output.exitCode,
                                              command: "conversation-prepare",
                                              productVersion: compatibilityContext.productVersion)
                }
            }
        }
        return decoded.requiringSuccess().flatMap { document in
            guard case .result(let payload) = document,
                  let projection = ConversationDeliveryProjection(raw: payload, requestedTaskID: taskID) else {
                return .failure(.unreadable(tool: "harflow-ctl", exitCode: 0,
                                            stderr: "Malformed conversation-prepare result or mismatched target identity"))
            }
            return .success(projection)
        }
    }

    /// Sends one message. There is no automatic retry and no cancellation guard after launch:
    /// a received receipt is returned even if the calling task was cancelled meanwhile.
    ///
    /// The outcome is evidence about this invocation only. To retry, call again with the same
    /// request value; the bytes are identical. A later `.notDispatched` or `.engineError` does
    /// not clear an earlier `.uncertain`. After `.uncertain`, reconcile by reading the
    /// projection with ``conversationPrepare(taskID:)``.
    func conversationSend(_ request: ConversationDeliverySendRequest) async
        -> ConversationDeliveryOutcome<ConversationDeliverySendRequest, ConversationDeliverySendReceipt> {
        await conversationMutate(command: "conversation-send", body: request.body, request: request) {
            ConversationDeliverySendReceipt(raw: $0, matching: request)
        }
    }

    /// Cancels or promotes one queued message. The same no-retry, no-guard and evidence rules as
    /// ``conversationSend(_:)`` apply.
    func conversationControl(_ request: ConversationDeliveryControlRequest) async
        -> ConversationDeliveryOutcome<ConversationDeliveryControlRequest, ConversationDeliveryControlReceipt> {
        await conversationMutate(command: "conversation-control", body: request.body, request: request) {
            ConversationDeliveryControlReceipt(raw: $0, matching: request)
        }
    }

    /// Starts a task enrolled in conversation delivery under `profile`, appended after the
    /// request's own arguments.
    ///
    /// Launches have no idempotency key and are never retried automatically; no API retries one.
    /// The `conversation-delivery.v1` capability gate is a floor and does not prove that the
    /// runtime, backend and profile are qualified. See ``ConversationLaunchOutcome``.
    func conversationLaunch(_ request: RunRequest, profile: ConversationLaunchProfile) async -> ConversationLaunchOutcome {
        await conversationStart(command: "run",
                                options: request.arguments + ["--conversation-profile=\(profile.wireValue)"],
                                positionals: [])
    }

    /// Resumes a task under a conversation profile, with an optional turn cap. The same
    /// no-retry, floor and evidence rules as ``conversationLaunch(_:profile:)`` apply.
    ///
    /// A resume starts a successor task: the returned id is a new task, not the input id. This
    /// code deliberately does not compare them.
    func conversationResume(taskID: String, text: String, profile: ConversationLaunchProfile,
                            maxTurns: Int? = nil) async -> ConversationLaunchOutcome {
        var options: [String] = []
        if let maxTurns { options.append("--max-turns=\(maxTurns)") }
        options.append("--conversation-profile=\(profile.wireValue)")
        return await conversationStart(command: "resume", options: options, positionals: [taskID, text])
    }
}

// MARK: - Transport and classification

extension CtlClient {
    /// Stdout cap for projection reads. The ledger may reach 4 MiB and ctl escapes to ASCII.
    /// It bounds decoding, not memory, because the runner buffers. It is checked before any parse.
    static let conversationReadStdoutCap = 32 << 20
    /// Above the engine's 30-second session lock wait.
    static let conversationPrepareTimeout = 60.0
    /// Stdout cap for send, control and launch results.
    static let conversationMutationStdoutCap = 1 << 20
    /// The non-native path can wait about 30 seconds on the session lock and drain for about 50;
    /// terminating it after a claim can leave a claim held.
    static let conversationMutationTimeout = 120.0

    /// Maps a pre-launch cause to the plain failure `raw` reports for the same situation.
    static func toolError(for cause: ConversationDeliveryNotDispatchedCause, command: String) -> ToolError {
        switch cause {
        case .probeFailed(let error): return error
        case .missingCapability(let capability):
            return .unsupportedCommand(tool: "harflow-ctl", command: command, detail: "Missing capability \(capability)")
        case .cancelledBeforeLaunch:
            return WireEnvelope.incompatibility("operation cancelled before command launch")
        case .inputFile(let detail):
            return .unreadable(tool: "harflow-ctl", exitCode: 0, stderr: detail)
        case .launchFailed(let tool, let detail): return .launchFailed(tool: tool, detail: detail)
        case .usageRejected(let detail): return .unreadable(tool: "harflow-ctl", exitCode: 2, stderr: detail)
        }
    }

    /// Runs `run` or `resume` through the phase-tagged exchange and classifies it with the shared rules.
    func conversationStart(command: String, options: [String], positionals: [String]) async -> ConversationLaunchOutcome {
        let exchange = await conversationExchange(command: command, options: options, positionals: positionals,
                                                  timeout: Self.startTimeout)
        let classified: ConversationDeliveryOutcome<ConversationLaunchMarker, String>
        switch exchange {
        case .notLaunched(let cause):
            return .notDispatched(cause)
        case .launched(let launched):
            classified = classifyConversationMutation(launched, command: command, options: options,
                                                      request: ConversationLaunchMarker(), timeout: Self.startTimeout) {
                guard let id = $0["task_id"]?.stringValue, ConversationDeliveryWire.isIdentifier(id) else { return nil }
                return id
            }
        }
        switch classified {
        case .accepted(let taskID): return .launched(taskID: taskID)
        case .notDispatched(_, let cause): return .notDispatched(cause)
        case .engineError(_, let error): return .engineError(error)
        case .uncertain(_, .receiptIdentityMismatch):
            return .uncertain(.inconsistentEnvelope(exitCode: 0, detail: "launch result carries no usable task id"))
        case .uncertain(_, let cause) where cause.isExitThreeInconsistency:
            // The classifier has validated the envelope; a validated `unknown` document at exit 3 is
            // the engine's own "owner never answered" report. Keep its message.
            if case .launched(.success(let output)) = exchange,
               let unknown = CtlDocument.firstJSONObject(in: output.stdout)?["unknown"]?.objectValue {
                return .uncertain(.processFailure(.unknownOutcome(message: unknown["message"]?.stringValue ?? "")))
            }
            return .uncertain(cause)
        case .uncertain(_, let cause): return .uncertain(cause)
        }
    }

    func conversationMutate<Request: Equatable & Sendable, Receipt: Equatable & Sendable>(
        command: String, body: Data, request: Request, inputDirectory: URL = FileManager.default.temporaryDirectory,
        receipt: ([String: JSONValue]) -> Receipt?
    ) async -> ConversationDeliveryOutcome<Request, Receipt> {
        let input: ConversationDeliveryInputFile
        do {
            input = try ConversationDeliveryInputFile(body: body, baseDirectory: inputDirectory)
        } catch {
            return .notDispatched(request, cause: .inputFile(detail: error.localizedDescription))
        }
        defer { input.cleanUp() }
        let exchange = await conversationExchange(command: command, options: ["--monitor"],
                                                  positionals: [input.file.path],
                                                  timeout: Self.conversationMutationTimeout)
        switch exchange {
        case .notLaunched(let cause):
            return .notDispatched(request, cause: cause)
        case .launched(let launched):
            return classifyConversationMutation(launched, command: command, options: ["--monitor"],
                                                request: request, receipt: receipt)
        }
    }

    /// The same fresh probe, capability check, argv ordering and transport metrics as `raw`,
    /// but phase-tagged. There is deliberately no supersede guard after launch.
    func conversationExchange(command: String, options: [String], positionals: [String],
                              timeout: Double) async -> ConversationExchange {
        guard operationIsCurrent(), !Task.isCancelled else { return .notLaunched(.cancelledBeforeLaunch) }
        let probe = await VersionInfoClient(executable: executable, environment: environment,
                                            context: compatibilityContext, runner: runner).check(requiring: [.ctl])
        switch probe {
        case .failure(let error):
            return .notLaunched(.probeFailed(error))
        case .success(let info):
            guard info.capabilities.contains(CtlCapability.conversationDelivery) else {
                return .notLaunched(.missingCapability(CtlCapability.conversationDelivery))
            }
        }
        guard operationIsCurrent(), !Task.isCancelled else { return .notLaunched(.cancelledBeforeLaunch) }
        let argv = Self.argv(command, options: options, positionals: positionals)
        let transportStart = MonitorMetrics.begin()
        let output = await runner.run(executable: executable, arguments: argv, environment: environment,
                                      currentDirectory: nil, timeout: timeout)
        if let transportStart {
            let bytes = (try? output.get().stdout.count) ?? 0
            MonitorMetrics.end(transportStart, stage: .transport, bytes: bytes,
                               stderrBytes: (try? output.get().stderr.utf8.count) ?? 0)
        }
        return .launched(output)
    }

    /// Classifies by phase and source. Anything after launch that no row matches is uncertain.
    func classifyConversationMutation<Request: Equatable & Sendable, Receipt: Equatable & Sendable>(
        _ launched: Result<ProcessOutput, ToolError>, command: String, options: [String],
        request: Request, timeout: Double = CtlClient.conversationMutationTimeout,
        receipt decodeReceipt: ([String: JSONValue]) -> Receipt?
    ) -> ConversationDeliveryOutcome<Request, Receipt> {
        let output: ProcessOutput
        switch launched {
        case .failure(.launchFailed(let tool, let detail)):
            return .notDispatched(request, cause: .launchFailed(tool: tool, detail: detail))
        case .failure(let error):
            return .uncertain(request, cause: .processFailure(error))
        case .success(let value):
            output = value
        }
        if output.timedOut { return .uncertain(request, cause: .timedOut(seconds: timeout)) }
        if output.stdout.count > Self.conversationMutationStdoutCap {
            return .uncertain(request, cause: .outputTooLarge(bytes: output.stdout.count))
        }
        // Exit status 2 is not proof by itself and stderr text is never proof: the runner ignores the
        // termination reason, so a signal after durable admission can also read as 2. Only a
        // validated envelope with code `usage` at exit 2 proves non-dispatch.
        switch validateTransportOutput(output, command: command, options: options, timeout: timeout) {
        case .failure(.unsupportedCommand):
            return .uncertain(request, cause: .unreadableOutput(exitCode: output.exitCode, stderr: output.stderr))
        case .failure(.unreadable(_, let exitCode, let stderr)):
            return .uncertain(request, cause: .unreadableOutput(exitCode: exitCode, stderr: stderr))
        case .failure(let error):
            switch error {
            case .refused, .unsupportedVersion:
                return .uncertain(request, cause: .incompatibleEnvelope(error))
            default:
                return .uncertain(request, cause: .processFailure(error))
            }
        case .success:
            break
        }
        return classifyConversationEnvelope(output, request: request, receipt: decodeReceipt)
    }

    /// Classifies a validated envelope by its shape and exit status together.
    private func classifyConversationEnvelope<Request: Equatable & Sendable, Receipt: Equatable & Sendable>(
        _ output: ProcessOutput, request: Request, receipt decodeReceipt: ([String: JSONValue]) -> Receipt?
    ) -> ConversationDeliveryOutcome<Request, Receipt> {
        guard let document = CtlDocument.firstJSONObject(in: output.stdout) else {
            return .uncertain(request, cause: .unreadableOutput(exitCode: output.exitCode, stderr: output.stderr))
        }
        func inconsistent(_ detail: String) -> ConversationDeliveryOutcome<Request, Receipt> {
            .uncertain(request, cause: .inconsistentEnvelope(exitCode: output.exitCode, detail: detail))
        }
        switch (document["result"], document["error"]) {
        case (.some, .some):
            return inconsistent("both result and error")
        case (.some(let result), nil):
            guard output.exitCode == 0 else { return inconsistent("result with non-zero exit") }
            guard let object = result.objectValue, let decoded = decodeReceipt(object) else {
                return .uncertain(request, cause: .receiptIdentityMismatch)
            }
            return .accepted(decoded)
        case (nil, .some(let value)):
            guard let object = value.objectValue, let code = object.deliveryString("code") else {
                return inconsistent("malformed error object")
            }
            let message = object.deliveryString("message") ?? ""
            if output.exitCode == 2, code == "usage" {
                return .notDispatched(request, cause: .usageRejected(detail: message))
            }
            guard output.exitCode == 1 else { return inconsistent("error with exit other than 1") }
            var data: [String: JSONValue]?
            if let raw = object["data"], raw != .null {
                guard let structured = raw.objectValue else { return inconsistent("malformed error data") }
                data = structured
            }
            return .engineError(request, ConversationDeliveryEngineError(code: code, message: message, data: data))
        case (nil, nil):
            return inconsistent("neither result nor error")
        }
    }
}

// MARK: - ConversationDeliveryUncertainCause launch helpers

private extension ConversationDeliveryUncertainCause {
    /// An inconsistent envelope reported at exit 3.
    var isExitThreeInconsistency: Bool {
        if case .inconsistentEnvelope(exitCode: 3, _) = self { return true }
        return false
    }
}
