import Foundation

/// Supported public wire contracts; each evolves independently of product releases.
public enum WireContract: String, Sendable, CaseIterable {
    case ctl, setup, events, versionInfo

    public var format: String {
        switch self {
        case .ctl: return "harflow.ctl"
        case .setup: return "harflow.setup"
        case .events: return "harflow.event"
        case .versionInfo: return "harflow.version-info"
        }
    }

    public var capability: String {
        self == .versionInfo ? "version-info.v1" : "\(rawValue).v1"
    }

    /// The tool the user sees named when this contract's answer is refused. An event record is only
    /// refused while reading a `harflow-ctl` answer, so the event log is reported as `harflow-ctl`.
    public var toolName: String {
        switch self {
        case .ctl, .events: return "harflow-ctl"
        case .setup: return "harflow-setup"
        case .versionInfo: return "harflow-ctl version-info"
        }
    }

    /// The wire versions this app understands for this contract; the refusal check reads this set.
    /// The refusal message resolves its set by tool name, and `.ctl` and `.events` both report as
    /// "harflow-ctl", so the ctl and event log sets must stay equal while they share a tool name.
    public var understoodVersions: Set<Int> {
        switch self {
        case .ctl: return ctlContractVersions
        case .setup: return [setupContractVersion]
        case .events: return [eventLogVersion]
        case .versionInfo: return [versionInfoContractVersion]
        }
    }
}

/// The `harflow.version-info` wire version this app understands. Gated independently, like
/// `ctlContractVersions` (`CtlModels.swift`), `setupContractVersion` (`SetupClient.swift`) and
/// `eventLogVersion` (`Events.swift`).
public let versionInfoContractVersion = 1

/// Capabilities that qualify individual ctl operations beyond the base wire contract.
public enum CtlCapability {
    /// Qualifies reported execution costs and whole-snapshot cost coverage.
    public static let statisticsCostModel = "statistics-cost-model.v1"

    /// Bounded direct-human pending launch inventory and exact lookup.
    public static let taskPendingLaunch = "task-pending-launch.v1"
    /// Permits bounded task event pages with independent lifecycle evidence.
    public static let taskEventPage = "task-event-page.v1"

    /// Permits bounded, integrity-reported task prompt reads.
    public static let taskPrompt = "task-prompt.v1"

    /// Permits bounded reads of a task's stored repository differences.
    public static let taskChanges = "task-changes.v1"

    /// Permits bounded discovery of recorded direct task successors.
    public static let taskSuccessors = "task-successors.v1"

    /// Permits direct-caller activity reads of unsettled workflow executions.
    public static let workflowLiveActivity = "workflow-live-activity.v1"

    /// Allows caller and Monitor response channels to compete for the same exact checkpoint.
    public static let workflowSharedInteractions = "workflow-shared-interactions.v1"

    /// Binds workflow recovery to the checkpoint displayed to the user.
    public static let workflowAttentionCheckpoints = "workflow-attention-checkpoints.v1"

    /// Permits the Monitor response channel to answer caller-owned approval requests.
    public static let callerApprovalMonitorRespond = "caller-approvals.monitor-respond.v1"

    /// Permits typed conversation message delivery, control and projection reads.
    public static let conversationDelivery = "conversation-delivery.v1"

    /// Permits `continue`, which starts a fresh-session successor task. A consumer that gates Continue
    /// also requires `task-successors.v1` from the same fresh handshake, for reconciliation after an
    /// unknown outcome.
    public static let taskContinue = "task-continue.v1"

    /// Permits bounded task artifact metadata pages, including their optional error reasons.
    public static let taskArtifacts = "task-artifacts.v1"

    /// Qualifies the advisory `continuation_stop` observation on task status.
    public static let taskContinuationStop = "task-continuation-stop.v1"

    /// Qualifies the `cascade.observation` added to successful cancel results.
    public static let taskCancelCascade = "task-cancel-cascade.v1"

    /// Permits `backend-models`, the engine's advisory per-harness model listing.
    public static let backendModels = "backend-models.v1"
}

/// Numeric semantic version with bounded components and optional build metadata; no prereleases.
public struct HarflowVersion: Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public static let current = "0.0.14"

    public init?(_ text: String) {
        guard text.count <= 256 else { return nil }
        let parts = text.split(separator: "+", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        if parts.count == 2 {
            let identifiers = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard identifiers.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45
            } }) else { return nil }
        }
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3 else { return nil }
        var values: [Int] = []
        for number in numbers {
            guard !number.isEmpty, number.count <= 10, number.utf8.allSatisfy({ (48...57).contains($0) }),
                  number.count == 1 || number.first != "0", let value = Int(number), value <= 2_147_483_647 else { return nil }
            values.append(value)
        }
        major = values[0]
        minor = values[1]
        patch = values[2]
    }

    public func isCompatible(with other: HarflowVersion) -> Bool { major == other.major && minor == other.minor }
}

/// Lexical absolute paths preserve case and symlink spelling, including for roots not yet created.
public enum LexicalStateRoot {
    public static func normalize(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        var components: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                if !components.isEmpty { components.removeLast() }
            } else {
                components.append(part)
            }
        }
        return "/" + components.joined(separator: "/")
    }
}

/// The selected runtime's expected release line and store; invalid roots always fail closed.
public struct RuntimeCompatibilityContext: Sendable, Equatable {
    public let expectedStateRoot: String
    public let productVersion: String

    public init(expectedStateRoot: String, productVersion: String = HarflowVersion.current) {
        self.expectedStateRoot = LexicalStateRoot.normalize(expectedStateRoot) ?? ""
        self.productVersion = productVersion
    }

    public static func effectiveEnvironment(_ environment: [String: String]) -> [String: String] {
        var value = environment
        if value["HOME"] == nil { value["HOME"] = NSHomeDirectory() }
        return value
    }

    public static func derived(environment: [String: String]) -> RuntimeCompatibilityContext {
        let home = effectiveEnvironment(environment)["HOME"] ?? ""
        return RuntimeCompatibilityContext(expectedStateRoot: home + "/.harflow")
    }
}

/// Shared strict envelope validation, before payload interpretation or process-error handling.
public enum WireEnvelope {
    public static func incompatibility(_ detail: String) -> ToolError {
        .refused(code: incompatibleRuntimeCode, message: incompatibilityMessagePrefix + detail)
    }

    /// The refusal code of every runtime incompatibility.
    public static let incompatibleRuntimeCode = "incompatible_runtime"
    /// The start of every incompatibility message; the detail follows it.
    public static let incompatibilityMessagePrefix = "Incompatible Harflow runtime: "

    /// The incompatibility details this app produces. Several are interpolated, so those are prefix or
    /// pattern matchers shared by the producers above and any classifier. A consumer classifies by this
    /// list and treats any other detail as unclassified.
    public enum Detail {
        public static let foreignProductIdentity = "missing or foreign product identity"
        public static let invalidProductVersion = "invalid product_version"
        public static let invalidVersionInfo = "invalid version-info or selected state_root mismatch"
        public static let requiresDarwinArm64 = "app integration requires darwin/arm64"
        public static let releaseLineDiffersPrefix = "product major/minor release line differs"
        public static let unsupportedFormatPrefix = "unsupported "
        public static let unsupportedFormatSuffix = " format"
        public static let missingRequiredPrefix = "missing required "

        public static func unsupportedFormat(_ format: String) -> String {
            unsupportedFormatPrefix + format + unsupportedFormatSuffix
        }

        public static func releaseLineDiffers(from productVersion: String) -> String {
            releaseLineDiffersPrefix + " from \(productVersion)"
        }

        public static func missingCapability(_ capability: String) -> String {
            missingRequiredPrefix + capability + " capability"
        }

        public static func missingContract(_ capability: String) -> String {
            missingRequiredPrefix + capability + " contract/capability"
        }

        /// Whether `detail` is an `unsupported <format> format` detail.
        public static func isUnsupportedFormat(_ detail: String) -> Bool {
            detail.hasPrefix(unsupportedFormatPrefix) && detail.hasSuffix(unsupportedFormatSuffix)
                && detail.count > unsupportedFormatPrefix.count + unsupportedFormatSuffix.count
        }

        /// The detail of an incompatibility refusal this app produced, or `nil` for any other error.
        public static func of(_ error: ToolError) -> String? {
            guard case .refused(let code, let message) = error, code == WireEnvelope.incompatibleRuntimeCode,
                  message.hasPrefix(WireEnvelope.incompatibilityMessagePrefix) else { return nil }
            return String(message.dropFirst(WireEnvelope.incompatibilityMessagePrefix.count))
        }
    }

    public static func validate(_ document: [String: JSONValue], contract: WireContract,
                                productVersion: String = HarflowVersion.current) -> ToolError? {
        guard document["product"]?.stringValue == "harflow" else { return incompatibility(Detail.foreignProductIdentity) }
        guard document["format"]?.stringValue == contract.format else { return incompatibility(Detail.unsupportedFormat(contract.format)) }
        guard let wireVersion = document["v"]?.wireIntegerValue, contract.understoodVersions.contains(wireVersion) else {
            return .unsupportedVersion(tool: contract.toolName, version: document["v"]?.rendered() ?? "none")
        }
        guard let text = document["product_version"]?.stringValue, let writer = HarflowVersion(text) else {
            return incompatibility(Detail.invalidProductVersion)
        }
        if contract != .events {
            guard let consumer = HarflowVersion(productVersion), writer.isCompatible(with: consumer) else {
                return incompatibility(Detail.releaseLineDiffers(from: productVersion))
            }
        }
        return nil
    }

    /// Only known event-page result fields are normalized records; opaque user metadata is not inspected.
    public static func validateEventPage(_ document: [String: JSONValue]) -> ToolError? {
        let payload = document["result"]?.objectValue ?? document
        guard let records = payload["events"]?.arrayValue else { return nil }
        for record in records {
            guard let event = record.objectValue else { return incompatibility("invalid nested event") }
            if let error = validate(event, contract: .events) { return error }
        }
        return nil
    }

}

/// Strict version-info answer. Capabilities are checked per operation, not globally.
public struct VersionInfoDocument: Sendable {
    public let stateRoot: String
    public let productVersion: String
    public let contracts: [String: JSONValue]
    public let capabilities: Set<String>
    public let operatingSystem: String
    public let architecture: String

    public static let maximumBytes = 64 << 10

    public static func decode(stdout: Data, stderr: String = "", exitCode: Int32 = 0,
                              context: RuntimeCompatibilityContext,
                              requiring: Set<WireContract> = [.ctl]) -> Result<VersionInfoDocument, ToolError> {
        guard stdout.count <= maximumBytes, let object = JSONValue.parse(stdout)?.objectValue else {
            return .failure(WireEnvelope.incompatibility("version-info must be one bounded JSON document"))
        }
        if let error = WireEnvelope.validate(object, contract: .versionInfo, productVersion: context.productVersion) { return .failure(error) }
        if let error = object["error"]?.objectValue {
            return .failure(.refused(code: error["code"]?.stringValue ?? "error", message: error["message"]?.stringValue ?? ""))
        }
        guard exitCode == 0, object["component"]?.stringValue == "engine",
              let root = object["state_root"]?.stringValue, let normalized = LexicalStateRoot.normalize(root),
              !context.expectedStateRoot.isEmpty, normalized == context.expectedStateRoot,
              let contracts = object["contracts"]?.objectValue, let values = object["capabilities"]?.arrayValue,
              values.allSatisfy({ $0.stringValue != nil }), let operatingSystem = object["os"]?.stringValue,
              let architecture = object["architecture"]?.stringValue else {
            return .failure(WireEnvelope.incompatibility(WireEnvelope.Detail.invalidVersionInfo))
        }
        guard operatingSystem == "darwin", architecture == "arm64" else {
            return .failure(WireEnvelope.incompatibility(WireEnvelope.Detail.requiresDarwinArm64))
        }
        let capabilities = Set(values.compactMap(\.stringValue))
        for contract in requiring {
            guard capabilities.contains(contract.capability) else {
                return .failure(WireEnvelope.incompatibility(WireEnvelope.Detail.missingCapability(contract.capability)))
            }
            // The version-info envelope was validated above; it has no contracts-map entry.
            if contract == .versionInfo { continue }
            let advertised = contracts[contract.rawValue]?.objectValue
            guard advertised?["format"]?.stringValue == contract.format,
                  let advertisedVersion = advertised?["v"]?.wireIntegerValue,
                  contract.understoodVersions.contains(advertisedVersion) else {
                return .failure(WireEnvelope.incompatibility(WireEnvelope.Detail.missingContract(contract.capability)))
            }
        }
        return .success(VersionInfoDocument(stateRoot: normalized, productVersion: object["product_version"]!.stringValue!,
                                            contracts: contracts, capabilities: capabilities, operatingSystem: operatingSystem, architecture: architecture))
    }
}

/// Direct, uncached compatibility probe; never calls CtlClient or inspects state on disk.
public struct VersionInfoClient: Sendable {
    public let executable: String
    public let environment: [String: String]
    public let runner: any ProcessRunning
    public let context: RuntimeCompatibilityContext

    public init(executable: String, environment: [String: String], context: RuntimeCompatibilityContext,
                runner: any ProcessRunning = ProcessRunner()) {
        self.executable = executable
        self.environment = RuntimeCompatibilityContext.effectiveEnvironment(environment)
        self.context = context
        self.runner = runner
    }

    public func check(requiring: Set<WireContract> = [.ctl]) async -> Result<VersionInfoDocument, ToolError> {
        guard !context.expectedStateRoot.isEmpty, HarflowVersion(context.productVersion) != nil else {
            return .failure(WireEnvelope.incompatibility("invalid selected compatibility context"))
        }
        let result = await runner.run(executable: executable, arguments: ["version-info", "--json"],
                                      environment: environment, currentDirectory: nil, timeout: 10)
        return result.flatMap { output in
            guard !output.timedOut else { return .failure(.timedOut(tool: "harflow-ctl version-info", seconds: 10)) }
            return VersionInfoDocument.decode(stdout: output.stdout, stderr: output.stderr, exitCode: output.exitCode,
                                              context: context, requiring: requiring)
        }
    }
}
