import Foundation

// MARK: - ConversationDeliveryOutcome

/// Evidence about one invocation of a send or control command, and nothing else.
///
/// An outcome never states anything about an earlier attempt. Every case except `.accepted`
/// carries the complete request value, so the caller can retry with identical bytes. Nothing
/// retries automatically; a retry is the caller calling again with the same value. A retry's
/// `.notDispatched` or `.engineError` never downgrades an earlier `.uncertain`: the caller
/// holds that state.
///
/// `.accepted` is an admission or control receipt, not proof of consumption, and its status
/// is a snapshot.
public enum ConversationDeliveryOutcome<Request: Equatable & Sendable, Receipt: Equatable & Sendable>: Equatable, Sendable {
    /// Exit 0, a validated envelope with a result, and a receipt whose identities match.
    case accepted(Receipt)
    /// This invocation launched no command, or the command was positively identified as a
    /// parser rejection before it ran (exit 2 with a validated envelope whose code is `usage`).
    case notDispatched(Request, cause: ConversationDeliveryNotDispatchedCause)
    /// A validated envelope with an `error` object at exit 1. This is not evidence of
    /// non-admission: the engine reports the same envelope for failures after a durable
    /// admission, promotion or workflow publication. Deciding what to show is the caller's.
    case engineError(Request, ConversationDeliveryEngineError)
    /// The command launched and the outcome cannot be established from this invocation.
    /// This is the default for anything after launch that no other case matches.
    case uncertain(Request, cause: ConversationDeliveryUncertainCause)
}

// MARK: - ConversationDeliveryNotDispatchedCause

/// Why an invocation is known to have dispatched nothing.
public enum ConversationDeliveryNotDispatchedCause: Equatable, Sendable {
    /// The private request file could not be written.
    case inputFile(detail: String)
    /// The compatibility probe failed; no command was launched.
    case probeFailed(ToolError)
    /// The runtime does not advertise the required capability.
    case missingCapability(String)
    /// The owner generation changed or the task was cancelled before launch.
    case cancelledBeforeLaunch
    /// The operating system could not start the process.
    case launchFailed(tool: String, detail: String)
    /// The command line parser rejected the invocation: exit 2 with a validated envelope whose
    /// error code is `usage`. Parser text on stderr is never accepted as proof.
    case usageRejected(detail: String)
}

// MARK: - ConversationDeliveryEngineError

/// A structured engine refusal. Codes are an open set; none is a safe-to-retry allowlist.
public struct ConversationDeliveryEngineError: Equatable, Sendable {
    public let code: String
    public let message: String
    /// Additive `error.data`, such as the `published` fact, retained verbatim.
    public let data: [String: JSONValue]?
}

// MARK: - ConversationDeliveryUncertainCause

/// Why the outcome of a launched command cannot be established.
public enum ConversationDeliveryUncertainCause: Equatable, Sendable {
    /// The command did not finish within the bound and was terminated.
    case timedOut(seconds: Double)
    /// The runner failed after launch in a way other than a launch failure.
    case processFailure(ToolError)
    /// Stdout was not one JSON document.
    case unreadableOutput(exitCode: Int32, stderr: String)
    /// The envelope failed product, format, version or release-line validation.
    case incompatibleEnvelope(ToolError)
    /// Stdout exceeded the cap for this command.
    case outputTooLarge(bytes: Int)
    /// The document and exit status contradict each other or fit no known shape.
    case inconsistentEnvelope(exitCode: Int32, detail: String)
    /// A result carried a receipt with a missing, malformed or mismatched identity.
    case receiptIdentityMismatch
}
