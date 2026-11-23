import Combine
import Foundation
import HfRepository
import Mockable
import MonitorCore

// MARK: - StoreRecoveryUseCase

/// Public engine operations used by the General settings recovery surface.
@MainActor
protocol StoreRecoveryUseCase: Sendable {
    var lastCompletedReceipt: StateRecoveryResult? { get }
    var recoveryState: StoreRecoveryState { get }
    func recoveryStatePublisher() -> AnyPublisher<StoreRecoveryState, Never>
    func inspectStore() async
    func confirmRecovery(_ inspection: StateInspection)
    func cancelRecovery()
    func recoverStore(_ inspection: StateInspection) async
}

extension StoreRecoveryUseCase {
    var lastCompletedReceipt: StateRecoveryResult? { nil }
}

// MARK: - StoreRecoveryRouting

@Mockable
@MainActor
protocol StoreRecoveryRouting: Sendable {
    func revealBackup(_ receipt: StateRecoveryResult)
}

// MARK: - StoreRecoveryPresentation

/// State-bound row content for the Task store group. Backup, reset and resume stay hidden, and so does the reveal
/// of an earlier receipt, which is kept as data for R01.
struct StoreRecoveryPresentation: Equatable {
    /// Whether the backup, reset, resume and reveal actions are offered. Hidden by owner decision 2026-11-23 until
    /// the Rust store design (R01) decides how recovery is presented. Inspection and the status rows stay; the
    /// repository, use case and engine recovery path are unchanged.
    static let recoveryActionsAvailable = false

    /// The sentence shown while the runtime is not ready, before an inspection and during one.
    static let waitingMessage = "Inspect the task store to check compatibility. Inspection does not reset history."
    /// The note under an interrupted recovery.
    static let interruptedNote = "Inspect again before retrying. Any reported backup evidence is retained; "
        + "the operation may have partially completed."

    /// One labelled detail line.
    struct Row: Equatable {
        let label: String
        let value: String
    }

    var title = "Task store"
    var glyph: RowGlyph?
    var message: String? = StoreRecoveryPresentation.waitingMessage
    var root: String?
    var reason: String?
    /// The refusal code, kept on a detail line only when the engine gave no reason.
    var code: String?
    var backupPath: String?
    var phase: String?
    var operationID: String?
    var busy = false
    /// Whether the Inspect button is drawn.
    var canInspect = true
    /// Whether the drawn Inspect button is enabled: only while the runtime is ready.
    private(set) var inspectEnabled = true
    var requestTitle: String?
    var confirming = false
    /// Whether an earlier completed receipt exists. Data for R01; nothing draws it while recovery is hidden.
    var canReveal = false
    var completedBackupPath: String?
    var confirmationTitle = "Confirm backup and reset"
    /// Whether the archival warning that accompanies the review and confirm controls is shown.
    var showsArchivalWarning: Bool { requestTitle != nil || confirming }
    /// Whether the interrupted-recovery note is shown.
    private(set) var showsInterruptedNote = false
    /// Whether the "Show backup in Finder" control is drawn. Never while recovery actions are hidden.
    var offersReveal: Bool { Self.recoveryActionsAvailable && canReveal }

    /// The detail rows in display order.
    var rows: [Row] {
        [
            root.map { Row(label: "State root", value: $0) },
            reason.map { Row(label: "Reason", value: $0) },
            code.map { Row(label: "Code", value: $0) },
            backupPath.map { Row(label: "Backup path", value: $0) },
            operationID.map { Row(label: "Recovery operation", value: $0) },
            phase.map { Row(label: "Phase", value: $0) }
        ].compactMap(\.self)
    }

    init(state: StoreRecoveryState, receipt: StateRecoveryResult? = nil, runtimeReady: Bool = true) {
        self.completedBackupPath = receipt?.backupPath
        self.canReveal = receipt != nil
        var interrupted = false
        switch state {
        case .idle: break
        case .incompatible(let error):
            interrupted = applyRefusal(error)
        case .inspecting:
            self.title = "Inspecting task store…"
            self.glyph = .busy
            self.busy = true
            self.canInspect = false
        case .inspected(let inspection):
            interrupted = apply(inspection)
            if Self.recoveryActionsAvailable, inspection.recoverySupported, let proposal = inspection.recovery {
                self.requestTitle = proposal.resumable ? "Review interrupted recovery" : "Review backup and reset"
            }
        case .confirming(let inspection):
            interrupted = apply(inspection)
            // With recovery hidden, a confirmation published by the use case renders like an inspection.
            if Self.recoveryActionsAvailable {
                self.title = inspection.recovery?.resumable == true ? "Resume this recovery?" : "Back up and reset this store?"
                self.confirmationTitle = inspection.recovery?.resumable == true ? "Confirm resume recovery" : "Confirm backup and reset"
                self.confirming = true
                self.canInspect = false
            }
        case .recovering(let inspection):
            _ = apply(inspection)
            self.title = "Recovering task store…"
            self.glyph = .busy
            self.busy = true
            self.canInspect = false
        case .completed(let receipt):
            self.title = "Task store is ready"
            self.glyph = .done
            self.message = "Recovery completed. Previous history is archived in the backup; it is not imported into the new store."
            self.root = receipt.stateRoot
            self.backupPath = receipt.backupPath
            self.operationID = receipt.operationID
            self.phase = "completed"
            self.completedBackupPath = receipt.backupPath
            self.canInspect = true
            self.canReveal = true
        case .failed(let error, let inspection):
            if let inspection {
                // A recovery failure: unreachable while recovery is hidden, kept with its evidence.
                _ = apply(inspection)
                self.title = "Recovery could not finish"
                self.glyph = .attention
                applyEvidence(error)
            } else {
                // The inspection itself failed: the failure message, and for a refusal the code on one detail line.
                self.title = "Task store needs attention"
                self.glyph = .attention
                self.message = error.displayMessage
                self.code = error.refusalCode
            }
        }
        if !runtimeReady {
            self = Self.waiting(receipt: receipt)
        } else {
            self.showsInterruptedNote = interrupted && requestTitle == nil && !confirming && !busy
        }
    }

    /// The row while the runtime is not ready, whatever the store state: the waiting copy and a disabled Inspect.
    private static func waiting(receipt: StateRecoveryResult?) -> StoreRecoveryPresentation {
        var row = StoreRecoveryPresentation(state: .idle, receipt: receipt)
        row.inspectEnabled = false
        return row
    }

    /// Applies an inspection; returns whether it reports an interrupted recovery.
    private mutating func apply(_ inspection: StateInspection) -> Bool {
        switch inspection.status {
        case .ready:
            title = "Task store is compatible"
            glyph = .done
            message = nil
            root = nil
            reason = nil
            return false
        case .missing:
            title = "Task store has not been created"
        case .incompatible:
            title = "Task store needs attention"
        case .interrupted:
            title = "Recovery was interrupted"
        }
        glyph = .attention
        message = inspection.message
        root = inspection.stateRoot
        reason = inspection.reason.rawValue
        if inspection.status == .interrupted {
            backupPath = inspection.recovery?.backupPath
            phase = inspection.recovery?.phase
            operationID = inspection.recovery?.operationID
        }
        return inspection.status == .interrupted
    }

    /// Applies a store refusal; returns whether it reports an interrupted recovery.
    private mutating func applyRefusal(_ error: ToolError) -> Bool {
        let attention = StoreAttention(error: error)
        title = attention.title
        glyph = .attention
        message = attention.message
        reason = attention.reason
        code = attention.code
        root = attention.stateRoot
        if attention.isInterrupted { applyEvidence(error) }
        return attention.isInterrupted
    }

    private mutating func applyEvidence(_ error: ToolError) {
        message = error.displayMessage
        reason = error.stateRecoveryReason?.rawValue ?? reason
        if error.stateRecoveryReason == nil { code = error.refusalCode }
        root = error.refusalData?["state_root"]?.stringValue ?? root
        backupPath = error.refusalData?["backup_path"]?.stringValue ?? backupPath
        phase = error.refusalData?["phase"]?.stringValue ?? phase
        operationID = error.refusalData?["operation_id"]?.stringValue ?? operationID
    }
}
