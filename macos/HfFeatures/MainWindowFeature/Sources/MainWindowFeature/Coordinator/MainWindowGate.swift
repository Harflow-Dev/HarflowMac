import HfRepository
import MonitorCore

// MARK: - MainWindowGate

/// A main-pane gate that follows the work listing once the runtime is ready: the runtime answers, but this app
/// cannot use it. The sidebar gives way to the setup line and creation is blocked while one shows.
///
/// Classification is by an allowlist of the incompatibility details this app produces
/// (`WireEnvelope.Detail`); any other error is unclassified and falls to the listing gate or a later refresh note.
public enum MainWindowGate: Equatable, Sendable {
    /// The runtime answers with a contract this app does not understand. `status` is the app's refusal message; `code` is the
    /// refusal code for an incompatibility refusal, and `nil` for an unsupported contract version, which has none.
    case contractRefused(status: String, code: String?)
    /// The runtime lacks a feature the app requires. `code` is the refusal code, shown on a detail row, when there is one.
    case capabilityMissing(status: String, code: String?)

    /// The gate for the current listing error, or `nil`. Pure; safe off the main actor.
    nonisolated static func classify(runtimeReady: Bool, listError: ToolError?) -> MainWindowGate? {
        guard runtimeReady, let listError else { return nil }
        switch listError {
        case .unsupportedVersion:
            return .contractRefused(status: listError.displayMessage, code: nil)
        case .unsupportedCommand:
            return .capabilityMissing(status: listError.displayMessage, code: nil)
        default:
            guard let detail = WireEnvelope.Detail.of(listError) else { return nil }
            if detail.hasPrefix(WireEnvelope.Detail.missingRequiredPrefix) {
                return .capabilityMissing(status: listError.displayMessage, code: WireEnvelope.incompatibleRuntimeCode)
            }
            return isContractMismatch(detail)
                ? .contractRefused(status: listError.displayMessage, code: WireEnvelope.incompatibleRuntimeCode) : nil
        }
    }

    /// Whether the listing error is shown by a gate here, so no other surface prints it.
    nonisolated static func owns(_ listError: ToolError?) -> Bool {
        classify(runtimeReady: true, listError: listError) != nil
    }

    private nonisolated static func isContractMismatch(_ detail: String) -> Bool {
        typealias Detail = WireEnvelope.Detail
        return detail == Detail.foreignProductIdentity
            || detail == Detail.invalidProductVersion
            || detail == Detail.invalidVersionInfo
            || detail == Detail.requiresDarwinArm64
            || detail.hasPrefix(Detail.releaseLineDiffersPrefix)
            || Detail.isUnsupportedFormat(detail)
    }
}

// MARK: - LoadingWorkError

/// The first work listing's failure as the loading gate shows it: the engine's sentence, and the refusal code on a
/// detail row instead of inside the sentence (unless an engine reason already explains the refusal).
public struct LoadingWorkError: Equatable, Sendable {
    public let message: String
    public let code: String?

    public init(message: String, code: String? = nil) {
        self.message = message
        self.code = code
    }

    nonisolated init(error: ToolError) {
        self.message = error.displayMessage
        self.code = error.stateRecoveryReason == nil ? error.refusalCode : nil
    }
}
