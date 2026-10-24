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

/// State-bound panel content. Only completed engine receipts expose a reveal action.
struct StoreRecoveryPresentation: Equatable {
    var title = "Task store"
    var message = "Inspect the task store to check compatibility. Inspection does not reset history."
    var root: String?
    var reason: String?
    var backupPath: String?
    var phase: String?
    var operationID: String?
    var busy = false
    var canInspect = true
    var requestTitle: String?
    var confirming = false
    var canReveal = false
    var completedBackupPath: String?
    var confirmationTitle = "Confirm backup and reset"

    init(state: StoreRecoveryState, receipt: StateRecoveryResult? = nil) {
        self.completedBackupPath = receipt?.backupPath
        self.canReveal = receipt != nil
        switch state {
        case .idle: break
        case .incompatible(let error):
            self.title = "Task store needs attention"
            apply(error)
        case .inspecting:
            self.title = "Inspecting task store…"
            self.busy = true
            self.canInspect = false
        case .inspected(let inspection):
            apply(inspection)
            if inspection.recoverySupported, let proposal = inspection.recovery {
                self.requestTitle = proposal.resumable ? "Review interrupted recovery" : "Review backup and reset"
            }
        case .confirming(let inspection):
            apply(inspection)
            self.title = inspection.recovery?.resumable == true ? "Resume this recovery?" : "Back up and reset this store?"
            self.confirmationTitle = inspection.recovery?.resumable == true ? "Confirm resume recovery" : "Confirm backup and reset"
            self.confirming = true
            self.canInspect = false
        case .recovering(let inspection):
            apply(inspection)
            self.title = "Recovering task store…"
            self.busy = true
            self.canInspect = false
        case .completed(let receipt):
            self.title = "Task store is ready"
            self.message = "Recovery completed. Previous history is archived in the backup; it is not imported into the new store."
            self.root = receipt.stateRoot
            self.backupPath = receipt.backupPath
            self.operationID = receipt.operationID
            self.phase = "completed"
            self.completedBackupPath = receipt.backupPath
            self.canInspect = true
            self.canReveal = true
        case .failed(let error, let inspection):
            if let inspection { apply(inspection) }
            self.title = "Recovery could not finish"
            apply(error)
        }
    }

    private mutating func apply(_ inspection: StateInspection) {
        title = switch inspection.status {
        case .ready: "Task store is compatible"
        case .missing: "Task store has not been created"
        case .incompatible: "Task store needs attention"
        case .interrupted: "Recovery was interrupted"
        }
        message = inspection.message
        root = inspection.stateRoot
        reason = inspection.reason.rawValue
        backupPath = inspection.recovery?.backupPath
        phase = inspection.recovery?.phase
        operationID = inspection.recovery?.operationID
    }

    private mutating func apply(_ error: ToolError) {
        message = error.message
        reason = error.stateRecoveryReason?.rawValue ?? error.refusalCode
        root = error.refusalData?["state_root"]?.stringValue ?? root
        backupPath = error.refusalData?["backup_path"]?.stringValue ?? backupPath
        phase = error.refusalData?["phase"]?.stringValue ?? phase
        operationID = error.refusalData?["operation_id"]?.stringValue ?? operationID
    }
}
