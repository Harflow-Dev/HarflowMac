import MonitorCore

public extension ToolError {
    /// The engine's own sentence of a refusal, without the "(code)" suffix and without the takeover headline.
    /// `nil` for every case that is not a refusal.
    var refusalMessage: String? {
        switch self {
        case .refused(_, let message), .structuredRefusal(_, let message, _): message
        default: nil
        }
    }

    /// The message a gate or a status row shows: a refusal's own sentence when it has one, otherwise `message`.
    /// An empty refusal reads "Refused.", so the code never returns to the main text.
    /// The refusal code is shown on a separate detail line, never inside this text.
    var displayMessage: String {
        guard let refusalMessage else { return message }
        return refusalMessage.isEmpty ? "Refused." : refusalMessage
    }

    /// The refusal code a detail line shows next to `displayMessage`: the code of a refusal, unless an engine
    /// reason already explains it (`stateRecoveryReason`). `nil` for every case that is not a refusal.
    var detailCode: String? {
        stateRecoveryReason == nil ? refusalCode : nil
    }
}
