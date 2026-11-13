import Foundation

// MARK: - BackendControlFacts

/// What `harflow-ctl backends --json` reports about the run-option controls of one harness:
/// whether a model can be chosen, which reasoning-effort levels it accepts, and whether it honours
/// a turn cap. Decoding is conservative: a missing or malformed field is recorded as unknown
/// (`nil`, `.unknown`) and never makes the entry fail to decode, because a failed entry fails the
/// whole document.
public struct BackendControlFacts: Equatable, Sendable {
    /// The engine's reasoning-effort block, reduced to what the app needs.
    public struct Effort: Equatable, Sendable {
        /// Whether the harness accepts a reasoning-effort parameter at all.
        public let acceptsParameter: Bool
        /// The accepted levels, in the engine's order. Unknown level names are kept as reported.
        public let levels: [String]

        /// Creates an effort block.
        public init(acceptsParameter: Bool, levels: [String]) {
            self.acceptsParameter = acceptsParameter
            self.levels = levels
        }
    }

    /// Whether the harness declares a `model_selection` qualification feature, and its state.
    public enum ModelSelectionGate: Equatable, Sendable {
        /// The qualification document lists features, and none is `model_selection`: no gate applies.
        case notDeclared
        /// A `model_selection` row is present and trusted (`ok` with a seeded or auto-probed source).
        case ready
        /// A `model_selection` row is present but not trusted, or does not decode.
        case notReady
        /// The qualification document is missing, malformed, or reports `unavailable_reason`.
        case unknown
    }

    /// `capabilities.supports_model_selection`; `nil` when missing or not a bool.
    public let supportsModelSelection: Bool?
    /// `capabilities.supports_turn_cap`; `nil` when missing or not a bool.
    public let supportsTurnCap: Bool?
    /// `capabilities.reasoning_effort`; `nil` when the block is missing or malformed.
    public let effort: Effort?
    /// The `model_selection` qualification gate.
    public let modelSelection: ModelSelectionGate

    /// Every fact unknown.
    public static let unknown = BackendControlFacts()

    /// Creates facts directly (tests and previews).
    public init(
        supportsModelSelection: Bool? = nil,
        supportsTurnCap: Bool? = nil,
        effort: Effort? = nil,
        modelSelection: ModelSelectionGate = .unknown
    ) {
        self.supportsModelSelection = supportsModelSelection
        self.supportsTurnCap = supportsTurnCap
        self.effort = effort
        self.modelSelection = modelSelection
    }

    /// Decodes the `capabilities` and `qualification` values of one backend entry.
    public init(capabilities: JSONValue?, qualification: JSONValue?) {
        let capabilities = capabilities?.objectValue
        supportsModelSelection = capabilities?["supports_model_selection"]?.boolValue
        supportsTurnCap = capabilities?["supports_turn_cap"]?.boolValue
        effort = Self.decodeEffort(capabilities?["reasoning_effort"])
        modelSelection = Self.decodeGate(qualification)
    }

    private static func decodeEffort(_ value: JSONValue?) -> Effort? {
        guard let block = value?.objectValue,
              let accepts = block["accepts_parameter"]?.boolValue,
              let rows = block["levels"]?.arrayValue else { return nil }
        let levels = rows.compactMap(\.stringValue)
        guard levels.count == rows.count, levels.allSatisfy({ !$0.isEmpty }),
              Set(levels).count == levels.count else { return nil }
        return Effort(acceptsParameter: accepts, levels: levels)
    }

    private static func decodeGate(_ value: JSONValue?) -> ModelSelectionGate {
        guard let document = value?.objectValue, document["unavailable_reason"] == nil,
              let features = document["features"]?.objectValue else { return .unknown }
        guard let row = features["model_selection"] else { return .notDeclared }
        guard let feature = BackendQualificationFeature(row), feature.isReady else { return .notReady }
        return .ready
    }
}
