import HfRepository
import MonitorCore

// MARK: - MainWindowGate

/// A main-pane gate that follows the work listing or the task store once the runtime is ready: the runtime answers, but this
/// app cannot use it, or the store refuses work. Creation is blocked while one shows. A contract or capability gate also
/// gives the sidebar over to the setup line; the store gate keeps the populated sidebar and its store link, as drawn.
///
/// Contract and capability classification is by an allowlist of the incompatibility details this app produces
/// (`WireEnvelope.Detail`); any other error is unclassified and falls to the listing gate or a later refresh note.
public enum MainWindowGate: Equatable, Sendable {
    /// The runtime answers with a contract this app does not understand. `status` is the app's refusal message; `code` is the
    /// refusal code for an incompatibility refusal, and `nil` for an unsupported contract version, which has none.
    case contractRefused(status: String, code: String?)
    /// The runtime lacks a feature the app requires. `code` is the refusal code, shown on a detail row, when there is one.
    case capabilityMissing(status: String, code: String?)
    /// The task store refuses work: the engine's sentence and the State root, Reason or Code detail rows.
    case storeUnusable(StoreAttention)

    /// The gate for the current listing error and store state, or `nil`. Pure; safe off the main actor.
    ///
    /// The store gate is keyed off the shared store state, which carries a refusal reported by the listing and the
    /// Settings inspection. It wins over the contract cases, because a refusing store explains the failing listing.
    /// A confirmation or a recovery in flight, a failed inspection, a completed recovery and a ready or missing
    /// inspection raise no gate.
    nonisolated static func classify(runtimeReady: Bool, listError: ToolError?, storeState: StoreRecoveryState) -> MainWindowGate? {
        guard runtimeReady else { return nil }
        if let attention = storeAttention(storeState) { return .storeUnusable(attention) }
        guard let listError else { return nil }
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
        classify(runtimeReady: true, listError: listError, storeState: .idle) != nil
    }

    /// Whether the gate replaces the sidebar body with the setup line. The store gate does not: the drawing keeps the
    /// populated sidebar and its store link.
    var givesSidebarToSetupLine: Bool {
        if case .storeUnusable = self { return false }
        return true
    }

    private nonisolated static func storeAttention(_ state: StoreRecoveryState) -> StoreAttention? {
        switch state {
        case .incompatible(let error): StoreAttention.from(refusal: error)
        case .inspected(let inspection): StoreAttention.from(inspection: inspection)
        case .idle, .inspecting, .confirming, .recovering, .completed, .failed: nil
        }
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
        self.code = error.detailCode
    }
}
