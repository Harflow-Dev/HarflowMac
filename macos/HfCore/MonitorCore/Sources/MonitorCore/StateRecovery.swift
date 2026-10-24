import Foundation

// MARK: - StateRecoveryReason

/// Stable engine-owned state diagnostics; unknown additive reasons remain available for display.
public struct StateRecoveryReason: RawRepresentable, Equatable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let compatible = Self(rawValue: "compatible")
    public static let recoveryInterrupted = Self(rawValue: "recovery_interrupted")
    public static let activeOwner = Self(rawValue: "active_owner")
    public static let staleConfirmation = Self(rawValue: "stale_confirmation")
}

// MARK: - StateRecoveryProposal

/// An opaque engine confirmation bound to one inspection of one selected root.
public struct StateRecoveryProposal: Equatable, Sendable {
    public let operationID: String
    public let confirmationToken: String
    public let backupPath: String
    public let phase: String
    public let resumable: Bool

    public init?(_ value: [String: JSONValue]) {
        guard let operationID = value["operation_id"]?.stringValue,
              operationID.count == 32, operationID.allSatisfy({ "0123456789abcdef".contains($0) }),
              let confirmationToken = value["confirmation_token"]?.stringValue, !confirmationToken.isEmpty,
              let backupPath = value["backup_path"]?.stringValue, LexicalStateRoot.normalize(backupPath) == backupPath,
              let phase = value["phase"]?.stringValue, !phase.isEmpty,
              let resumable = value["resumable"]?.boolValue else { return nil }
        self.operationID = operationID
        self.confirmationToken = confirmationToken
        self.backupPath = backupPath
        self.phase = phase
        self.resumable = resumable
    }
}

// MARK: - StateInspection

/// A read-only engine report, independent of executable qualification.
public struct StateInspection: Equatable, Sendable {
    public enum Status: String, Sendable { case ready, incompatible, missing, interrupted }
    public let stateRoot: String
    public let engineVersion: String
    public let status: Status
    public let reason: StateRecoveryReason
    public let message: String
    public let recoverySupported: Bool
    public let cooperativeOwnershipOnly: Bool
    public let observedStore: [String: JSONValue]?
    public let recovery: StateRecoveryProposal?

    public init?(_ value: [String: JSONValue]) {
        guard let stateRoot = value["state_root"]?.stringValue, LexicalStateRoot.normalize(stateRoot) == stateRoot,
              let engineVersion = value["engine_version"]?.stringValue, HarflowVersion(engineVersion) != nil,
              let rawStatus = value["status"]?.stringValue, let status = Status(rawValue: rawStatus),
              let reason = value["reason"]?.stringValue, !reason.isEmpty,
              let message = value["message"]?.stringValue,
              let recoverySupported = value["recovery_supported"]?.boolValue,
              let cooperativeOwnershipOnly = value["cooperative_ownership_only"]?.boolValue else { return nil }
        let proposal = value["recovery"]?.objectValue.flatMap(StateRecoveryProposal.init)
        if value["recovery"] != nil, value["recovery"] != .null, proposal == nil { return nil }
        if recoverySupported, proposal == nil || status == .ready || status == .missing { return nil }
        if !recoverySupported, proposal != nil { return nil }
        self.stateRoot = stateRoot
        self.engineVersion = engineVersion
        self.status = status
        self.reason = StateRecoveryReason(rawValue: reason)
        self.message = message
        self.recoverySupported = recoverySupported
        self.cooperativeOwnershipOnly = cooperativeOwnershipOnly
        self.observedStore = value["observed_store"]?.objectValue
        self.recovery = proposal
    }
}

// MARK: - StateRecoveryResult

/// Durable receipt returned by the engine after explicit recovery or an idempotent repeat.
public struct StateRecoveryResult: Equatable, Sendable {
    public let stateRoot: String
    public let engineVersion: String
    public let operationID: String
    public let backupID: String
    public let backupPath: String

    public init?(_ value: [String: JSONValue]) {
        guard let stateRoot = value["state_root"]?.stringValue, LexicalStateRoot.normalize(stateRoot) == stateRoot,
              let engineVersion = value["engine_version"]?.stringValue, HarflowVersion(engineVersion) != nil,
              let operationID = value["operation_id"]?.stringValue,
              operationID.count == 32, operationID.allSatisfy({ "0123456789abcdef".contains($0) }),
              let backupID = value["backup_id"]?.stringValue, backupID == operationID,
              let backupPath = value["backup_path"]?.stringValue, LexicalStateRoot.normalize(backupPath) == backupPath,
              value["status"]?.stringValue == "completed", value["phase"]?.stringValue == "completed" else { return nil }
        self.stateRoot = stateRoot
        self.engineVersion = engineVersion
        self.operationID = operationID
        self.backupID = backupID
        self.backupPath = backupPath
    }
}

public extension ToolError {
    /// Additive engine error metadata, including any partial-backup evidence.
    var refusalData: [String: JSONValue]? {
        if case .structuredRefusal(_, _, let data) = self { return data }
        return nil
    }
    /// Store refusals require a dedicated recovery surface while the executable stays qualified.
    var isStateRecoveryRefusal: Bool {
        ["state_incompatible", "state_recovery_failed", "state_recovery_stale", "state_recovery_unsafe"].contains(refusalCode ?? "")
    }
    var stateRecoveryReason: StateRecoveryReason? {
        refusalData?["reason"]?.stringValue.map { StateRecoveryReason(rawValue: $0) }
    }
}

public extension CtlClient {
    /// Inspects through the public capability-gated command without opening private store files.
    func inspectState() async -> Result<StateInspection, ToolError> {
        await stateResult("state-inspect").flatMap { payload in
            guard let inspection = StateInspection(payload), inspection.stateRoot == compatibilityContext.expectedStateRoot else {
                return .failure(WireEnvelope.incompatibility("state-inspect returned a malformed or different state_root"))
            }
            return .success(inspection)
        }
    }

    /// Explicitly confirms exactly the supplied inspection. Never obtains or invents a new token.
    func recoverState(inspection: StateInspection) async -> Result<StateRecoveryResult, ToolError> {
        guard inspection.stateRoot == compatibilityContext.expectedStateRoot,
              inspection.recoverySupported, let proposal = inspection.recovery else {
            return .failure(.refused(code: "state_recovery_stale", message: "A current recovery inspection is required."))
        }
        let options = ["--operation-id=\(proposal.operationID)", "--confirmation-token=\(proposal.confirmationToken)"]
        return await stateResult("state-recover", options: options, timeout: Self.takeoverTimeout)
            .flatMap { payload in
                guard let receipt = StateRecoveryResult(payload), receipt.stateRoot == inspection.stateRoot,
                      receipt.engineVersion == inspection.engineVersion, receipt.operationID == proposal.operationID,
                      receipt.backupPath == proposal.backupPath else {
                    return .failure(WireEnvelope.incompatibility("state-recover returned a receipt for a different operation"))
                }
                return .success(receipt)
            }
    }

    private func stateResult(_ command: String, options: [String] = [], timeout: Double = quickTimeout) async -> Result<[String: JSONValue], ToolError> {
        await raw(command, options: options, timeout: timeout, requiringCapability: "state-recovery.v1")
            .flatMap { output in
                CtlDocument.decode(stdout: output.stdout, stderr: output.stderr, exitCode: output.exitCode, command: command,
                                   productVersion: compatibilityContext.productVersion)
            }.requiringSuccess().flatMap { document in
                guard case .result(let value) = document else {
                    return .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "\(command) returned no result"))
                }
                return .success(value)
            }
    }
}

// MARK: - Managed runtime readiness errors

public extension ToolError {
    /// Preparation and acquisition failure share the install-status surface, never a list incident.
    var isManagedRuntimeUnavailable: Bool {
        guard let code = refusalCode else { return false }
        return code == "managed_runtime_preparing" || code == "managed_runtime_failed" || code == "managed_runtime_install_required"
    }
}
