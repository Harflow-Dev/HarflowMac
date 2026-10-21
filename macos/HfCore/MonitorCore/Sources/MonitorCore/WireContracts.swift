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
}

/// Numeric semantic version with bounded components and optional build metadata; no prereleases.
public struct HarflowVersion: Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public static let current = "0.0.1"

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
        .refused(code: "incompatible_runtime", message: "Incompatible Harflow runtime: " + detail)
    }

    public static func validate(_ document: [String: JSONValue], contract: WireContract,
                                productVersion: String = HarflowVersion.current) -> ToolError? {
        guard document["product"]?.stringValue == "harflow" else { return incompatibility("missing or foreign product identity") }
        guard document["format"]?.stringValue == contract.format else { return incompatibility("unsupported \(contract.format) format") }
        guard document["v"]?.wireIntegerValue == 1 else {
            return .unsupportedVersion(tool: contract.format, version: document["v"]?.rendered() ?? "none")
        }
        guard let text = document["product_version"]?.stringValue, let writer = HarflowVersion(text) else {
            return incompatibility("invalid product_version")
        }
        if contract != .events {
            guard let consumer = HarflowVersion(productVersion), writer.isCompatible(with: consumer) else {
                return incompatibility("product major/minor release line differs from \(productVersion)")
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
            return .failure(WireEnvelope.incompatibility("invalid version-info or selected state_root mismatch"))
        }
        guard operatingSystem == "darwin", architecture == "arm64" else {
            return .failure(WireEnvelope.incompatibility("app integration requires darwin/arm64"))
        }
        let capabilities = Set(values.compactMap(\.stringValue))
        for contract in requiring {
            guard capabilities.contains(contract.capability) else {
                return .failure(WireEnvelope.incompatibility("missing required \(contract.capability) capability"))
            }
            // The version-info envelope was validated above; it has no contracts-map entry.
            if contract == .versionInfo { continue }
            let advertised = contracts[contract.rawValue]?.objectValue
            guard advertised?["format"]?.stringValue == contract.format,
                  advertised?["v"]?.wireIntegerValue == 1 else {
                return .failure(WireEnvelope.incompatibility("missing required \(contract.capability) contract/capability"))
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
