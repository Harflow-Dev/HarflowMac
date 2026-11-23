import MonitorCore

// MARK: - StoreAttention

/// What a surface shows when the task store refuses work: one title, the engine's sentence and the detail lines.
/// Settings and the main window share this rule, because feature packages cannot import each other.
public struct StoreAttention: Equatable, Sendable {
    public let title: String
    /// The engine's sentence, without its refusal code.
    public let message: String
    public let stateRoot: String?
    /// The engine's reason (`missing_root`, `foreign_store`, `recovery_interrupted`, ...).
    public let reason: String?
    /// The refusal code. Present only when the refusal carries no engine reason, so the code is kept on a detail line.
    public let code: String?

    public init(error: ToolError) {
        let reason = error.stateRecoveryReason?.rawValue
        self.title = Self.title(forReason: reason)
        self.message = error.displayMessage
        self.stateRoot = error.refusalData?["state_root"]?.stringValue
        self.reason = reason
        self.code = reason == nil ? error.refusalCode : nil
    }

    /// The attention for a store refusal; `nil` for any other error.
    public static func from(refusal error: ToolError) -> StoreAttention? {
        error.isStateRecoveryRefusal ? StoreAttention(error: error) : nil
    }

    /// Whether the refusal reports an interrupted recovery.
    public var isInterrupted: Bool { reason == StateRecoveryReason.recoveryInterrupted.rawValue }

    /// The title for an engine reason.
    public static func title(forReason reason: String?) -> String {
        switch reason {
        case StateRecoveryReason.recoveryInterrupted.rawValue: "Recovery was interrupted"
        case "missing_root": "Task store has not been created"
        default: "Task store needs attention"
        }
    }
}
