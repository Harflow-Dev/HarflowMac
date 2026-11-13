import Foundation

// MARK: - BackendAvailability

/// One backend as `harflow-ctl backends --json` reports it: its registered name, its binary, and
/// whether that binary is on the login PATH the Monitor runs `harflow-ctl` with. `installed` is
/// `nil` — unknown — whenever the field is missing or not a bool, never silently `false`: a wrong
/// or absent answer must never read as a confirmed "not found" (Code review round 1, finding 1).
public struct BackendAvailability: Equatable, Sendable {
    public let backend: String
    public let binary: String
    public let installed: Bool?
    public let supportsCallerApprovals: Bool
    /// The run-option facts (model, effort, turn cap); every fact unknown when the engine omits them.
    public let controls: BackendControlFacts

    public init(
        backend: String,
        binary: String,
        installed: Bool?,
        supportsCallerApprovals: Bool = false,
        controls: BackendControlFacts = .unknown
    ) {
        self.backend = backend
        self.binary = binary
        self.installed = installed
        self.supportsCallerApprovals = supportsCallerApprovals
        self.controls = controls
    }

    public init?(_ value: JSONValue) {
        guard let object = value.objectValue,
              let backend = object["backend"]?.stringValue, !backend.isEmpty,
              let binary = object["binary"]?.stringValue else { return nil }
        self.backend = backend
        self.binary = binary
        // `.boolValue` itself already answers `nil` for a missing key or a non-bool value — no
        // `?? false` fallback here, so either case reads as "unknown," never "confirmed absent."
        installed = object["installed"]?.boolValue
        supportsCallerApprovals = object["capabilities"]?.objectValue?["supports_caller_approvals"]?.boolValue ?? false
        controls = BackendControlFacts(capabilities: object["capabilities"], qualification: object["qualification"])
    }
}
