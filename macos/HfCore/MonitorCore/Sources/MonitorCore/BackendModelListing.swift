import Foundation

// MARK: - BackendModel

/// One model a harness reports as selectable, as listed by `harflow-ctl backend-models`.
public struct BackendModel: Equatable, Sendable {
    /// The value to pass as the run's model. Never empty.
    public let id: String
    /// A human-readable name; may equal the id.
    public let label: String
    /// `true` or `false` when the source says whether this is the harness default, `nil` when it does not say.
    public let isDefault: Bool?
    /// The selectable reasoning-effort levels for this model, in the backend's order. `nil`: the source
    /// says nothing about levels. Empty: the source lists levels and none is selectable.
    public let effortLevels: [String]?

    /// Creates a model row.
    public init(id: String, label: String, isDefault: Bool? = nil, effortLevels: [String]? = nil) {
        self.id = id
        self.label = label
        self.isDefault = isDefault
        self.effortLevels = effortLevels
    }
}

// MARK: - BackendModelListing

/// The result of one `harflow-ctl backend-models --backend NAME` read: an advisory, user-scoped view of
/// the models one harness says it can select. `state`, `reason` and `source` keep values this app does
/// not know as `.unrecognized`, because the engine may add values without a new contract version.
public struct BackendModelListing: Equatable, Sendable {
    /// Whether the harness could be listed.
    public enum State: Equatable, Sendable {
        case available
        case notInstalled
        case unsupported
        case unavailable
        case unrecognized(String)

        init(wire: String) {
            switch wire {
            case "available": self = .available
            case "not_installed": self = .notInstalled
            case "unsupported": self = .unsupported
            case "unavailable": self = .unavailable
            default: self = .unrecognized(wire)
            }
        }
    }

    /// Why an `unavailable` listing is empty.
    public enum Reason: Equatable, Sendable {
        case timeout
        case exitNonzero
        case authRequired
        case unparseable
        case sourceMissing
        case outputCeiling
        case spawnFailed
        case unrecognized(String)

        init(wire: String) {
            switch wire {
            case "timeout": self = .timeout
            case "exit_nonzero": self = .exitNonzero
            case "auth_required": self = .authRequired
            case "unparseable": self = .unparseable
            case "source_missing": self = .sourceMissing
            case "output_ceiling": self = .outputCeiling
            case "spawn_failed": self = .spawnFailed
            default: self = .unrecognized(wire)
            }
        }
    }

    /// Where the rows came from. May be present for any state, for example `not_installed` with documented aliases.
    public enum Source: Equatable, Sendable {
        case cliOutput
        case harnessCache
        case documentedAliases
        case configAliases
        case unrecognized(String)

        init(wire: String) {
            switch wire {
            case "cli_output": self = .cliOutput
            case "harness_cache": self = .harnessCache
            case "documented_aliases": self = .documentedAliases
            case "config_aliases": self = .configAliases
            default: self = .unrecognized(wire)
            }
        }
    }

    /// The requested backend name.
    public let backend: String
    public let state: State
    /// Present for `unavailable` listings; `nil` otherwise.
    public let reason: Reason?
    public let source: Source?
    /// Always `"user"` in contract v1; kept as reported.
    public let scope: String
    /// Always `true` in contract v1: the harness may accept an id it does not list, or refuse one it does.
    public let advisory: Bool
    /// Always `nil` in contract v1.
    public let harnessVersion: String?
    /// RFC 3339 time the source says it was written, as reported, or `nil`.
    public let sourceObservedAt: String?
    /// RFC 3339 time of this read, as reported.
    public let observedAt: String
    /// `true` when valid rows were removed by the engine's row or byte cap.
    public let truncated: Bool
    /// Rows the engine dropped as invalid or duplicate; truncated rows are not counted.
    public let droppedCount: Int
    /// The rows in the engine's order.
    public let models: [BackendModel]

    /// Creates a listing directly (tests and previews).
    public init(
        backend: String, state: State, reason: Reason? = nil, source: Source? = nil, scope: String = "user",
        advisory: Bool = true, harnessVersion: String? = nil, sourceObservedAt: String? = nil,
        observedAt: String = "", truncated: Bool = false, droppedCount: Int = 0, models: [BackendModel] = []
    ) {
        self.backend = backend
        self.state = state
        self.reason = reason
        self.source = source
        self.scope = scope
        self.advisory = advisory
        self.harnessVersion = harnessVersion
        self.sourceObservedAt = sourceObservedAt
        self.observedAt = observedAt
        self.truncated = truncated
        self.droppedCount = droppedCount
        self.models = models
    }

    /// Decodes the `result` object. Unknown extra fields are ignored; a missing required field or a field of
    /// the wrong type makes the whole document unreadable (`nil`).
    init?(result: [String: JSONValue]) {
        guard let backend = result["backend"]?.stringValue, !backend.isEmpty,
              let state = result["state"]?.stringValue,
              let scope = result["scope"]?.stringValue,
              let advisory = result["advisory"]?.boolValue,
              let observedAt = result["observed_at"]?.stringValue,
              let truncated = result["truncated"]?.boolValue,
              let droppedCount = result["dropped_count"]?.wireIntegerValue, droppedCount >= 0,
              let rows = result["models"]?.arrayValue,
              let reason = Self.optionalString(result["reason"]),
              let source = Self.optionalString(result["source"]),
              let harnessVersion = Self.optionalString(result["harness_version"]),
              let sourceObservedAt = Self.optionalString(result["source_observed_at"]) else { return nil }
        var models: [BackendModel] = []
        for row in rows {
            guard let model = Self.model(row) else { return nil }
            models.append(model)
        }
        self.init(
            backend: backend, state: State(wire: state), reason: reason.map(Reason.init(wire:)),
            source: source.map(Source.init(wire:)), scope: scope, advisory: advisory, harnessVersion: harnessVersion,
            sourceObservedAt: sourceObservedAt, observedAt: observedAt, truncated: truncated,
            droppedCount: droppedCount, models: models
        )
    }

    /// A nullable string field: `.some(nil)` when absent or null, `.some(value)` for a string, `nil` for any other type.
    private static func optionalString(_ value: JSONValue?) -> String?? {
        guard let value, value != .null else { return .some(nil) }
        guard let text = value.stringValue else { return nil }
        return .some(text)
    }

    private static func model(_ value: JSONValue) -> BackendModel? {
        guard let row = value.objectValue,
              let id = row["id"]?.stringValue, !id.isEmpty,
              let label = row["label"]?.stringValue else { return nil }
        var isDefault: Bool?
        if let flag = row["default"], flag != .null {
            guard let decoded = flag.boolValue else { return nil }
            isDefault = decoded
        }
        var levels: [String]?
        if let list = row["effort_levels"], list != .null {
            guard let items = list.arrayValue else { return nil }
            let decoded = items.compactMap(\.stringValue)
            guard decoded.count == items.count else { return nil }
            levels = decoded
        }
        return BackendModel(id: id, label: label, isDefault: isDefault, effortLevels: levels)
    }
}

// MARK: - BackendModelsOutcome

/// What one `backend-models` request produced. Every case other than `.listing` leaves the caller with no
/// engine-provided suggestions; the cases stay distinct so a later design can word them differently.
public enum BackendModelsOutcome: Equatable, Sendable {
    /// A readable listing, including `unavailable`, `not_installed` and `unsupported` states.
    case listing(BackendModelListing)
    /// The engine does not advertise `backend-models.v1` on a fresh handshake; the command never ran.
    case capabilityMissing
    /// The engine refused the caller (`agent_caller`, `caller_undecidable`, or an additive refusal code).
    /// `detail` is the bounded `error.data.detail` when the engine gave one.
    case refused(code: String, detail: String?)
    /// Anything else: transport failure, unreadable or oversized document, usage error, other engine error.
    case failed(ToolError)

    /// Largest accepted document, excluding one terminal newline: the engine's own printed-line ceiling.
    static let maximumDocumentBytes = 262_144

    /// Decodes `harflow-ctl backend-models --backend=NAME --json` output.
    static func decode(output: ProcessOutput, productVersion: String) -> BackendModelsOutcome {
        // The engine's ceiling covers the printed line without its newline.
        let documentBytes = output.stdout.count - (output.stdout.last == 0x0A ? 1 : 0)
        guard documentBytes <= maximumDocumentBytes else {
            return .failed(.unreadable(tool: "harflow-ctl", exitCode: output.exitCode, stderr: "backend-models exceeded document byte limit"))
        }
        let validated = CtlDocument.validatedDocument(
            stdout: output.stdout, stderr: output.stderr, exitCode: output.exitCode, command: "backend-models",
            productVersion: productVersion
        )
        switch validated {
        case .failure(.structuredRefusal(let code, _, let data)):
            return .refused(code: code, detail: data["detail"]?.stringValue)
        case .failure(let error):
            return .failed(error)
        case .success(.error(let code, let message)):
            return .failed(.refused(code: code, message: message))
        case .success(.document(let document)):
            guard output.exitCode == 0, let result = document["result"]?.objectValue,
                  let listing = BackendModelListing(result: result) else {
                return .failed(.unreadable(tool: "harflow-ctl", exitCode: output.exitCode, stderr: "Malformed backend-models document"))
            }
            return .listing(listing)
        }
    }
}

// MARK: - CtlClient

public extension CtlClient {
    /// Reads the models one harness reports as selectable, behind a fresh `backend-models.v1` handshake.
    /// The command takes no repository and starts no model call. The app is a direct caller; an engine that
    /// refuses the caller answers `.refused`. Never throws: every failure is an outcome.
    func backendModels(backend: String) async -> BackendModelsOutcome {
        guard Self.validBackendName(backend) else {
            return .failed(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Invalid backend name"))
        }
        let response = await raw("backend-models", options: ["--backend=\(backend)"], timeout: Self.quickTimeout,
                                 requiringCapability: CtlCapability.backendModels)
        guard operationIsCurrent(), !Task.isCancelled else {
            return .failed(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Backend models observation superseded"))
        }
        switch response {
        case .failure(.unsupportedCommand(_, _, let detail)) where detail == "Missing capability \(CtlCapability.backendModels)":
            return .capabilityMissing
        case .failure(let error):
            return .failed(error)
        case .success(let output):
            return BackendModelsOutcome.decode(output: output, productVersion: compatibilityContext.productVersion)
        }
    }

    private static func validBackendName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64
            && value.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) == (value.startIndex ..< value.endIndex)
    }
}
