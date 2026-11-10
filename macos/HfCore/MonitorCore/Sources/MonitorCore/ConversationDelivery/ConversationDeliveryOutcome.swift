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
    /// The runner failed after launch in a way other than a launch failure, or the engine
    /// reported an unknown outcome.
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

// MARK: - ConversationLaunchProfile

/// The conversation profile a launch enrolls the task under, rendered as the exact wire value of
/// `harflow-ctl run|resume --conversation-profile`.
public enum ConversationLaunchProfile: Equatable, Sendable {
    case native
    case shippedMedium35High

    /// The exact value the engine accepts.
    public var wireValue: String {
        switch self {
        case .native: return "native"
        case .shippedMedium35High: return "shipped-medium35-high"
        }
    }
}

// MARK: - ConversationLaunchMarker

/// Stands in for the request value the shared classifier carries; a launch has no replayable request.
struct ConversationLaunchMarker: Equatable, Sendable {}

// MARK: - ConversationLaunchOutcome

/// Evidence about one profiled launch (`run` or `resume`) or base Continue, and nothing else.
///
/// `.engineError` does not prove that no record exists. A refused launch can leave a task record
/// and a process behind: the engine can fail after spawning, persist the task, then terminate the
/// process and report the same error code it uses when nothing happened. Launches have no
/// idempotency key, so a retry can start a second task; they are never retried automatically and
/// no API here retries one. There is deliberately no refused case.
public enum ConversationLaunchOutcome: Equatable, Sendable {
    /// Exit 0, a validated acknowledgement and usable task id. Resources may still be pending;
    /// this is not evidence of task completion.
    case launched(taskID: String)
    /// No process was launched, or the command was positively identified as a parser rejection
    /// (exit 2 with a validated envelope whose code is `usage`).
    case notDispatched(ConversationDeliveryNotDispatchedCause)
    /// A validated envelope with an `error` object at exit 1. A task record may still exist.
    case engineError(ConversationDeliveryEngineError)
    /// The command launched and the outcome cannot be established, including exit 3 and a
    /// success envelope without a usable task id.
    case uncertain(ConversationDeliveryUncertainCause)
}
