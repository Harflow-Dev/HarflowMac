import Foundation

// MARK: - BackendQualificationIdentity

/// Engine-reported identity binding qualification evidence to an installed harness.
public struct BackendQualificationIdentity: Equatable, Sendable {
    /// Engine backend identifier.
    public let backend: String
    /// Installed harness version reported by the engine.
    public let version: String
    /// Absolute executable path selected for this evidence.
    public let executable: String
    /// Lowercase SHA-256 digest of the installed binary.
    public let binarySHA256: String
    /// Engine platform identifier used to qualify the binary.
    public let platform: String

    /// Decodes validated public engine evidence; malformed values are rejected.
    public init?(_ value: JSONValue) {
        guard let backend = value["backend"]?.stringValue, !backend.isEmpty,
              let version = value["version"]?.stringValue, !version.isEmpty,
              let executable = value["executable"]?.stringValue, executable.hasPrefix("/"),
              let digest = value["binary_sha256"]?.stringValue, digest.count == 64,
              digest.allSatisfy({ "0123456789abcdef".contains($0) }),
              let platform = value["platform"]?.stringValue, !platform.isEmpty else { return nil }
        self.backend = backend
        self.version = version
        self.executable = executable
        binarySHA256 = digest
        self.platform = platform
    }
}

// MARK: - BackendQualificationFeature

/// One feature's cached public evidence. Unknown sources never authorize a launch.
public struct BackendQualificationFeature: Equatable, Sendable {
    /// Known public evidence sources; only seeded and auto-probed success is ready.
    public enum Source: String, Sendable {
        /// Trusted engine-maintained version/platform seed.
        case seeded
        /// Evidence measured by an isolated engine probe.
        case autoProbed = "auto-probed"
        /// A required check failed.
        case failed
        /// A runtime failure invalidated earlier evidence.
        case failedAtRuntime = "failed-at-runtime"
        /// The harness or evidence is unavailable.
        case unavailable
        /// The engine or feature does not support qualification.
        case unsupported
        /// No measured or seeded evidence is available.
        case unknown
    }

    /// Engine-reported feature outcome; readiness also requires a trusted source.
    public let ok: Bool
    /// Provenance or failure classification reported by the engine.
    public let source: Source
    /// Failure or evidence detail, bounded to 1,000 characters.
    public let reason: String
    /// Installed harness identity associated with these results.
    public let identity: BackendQualificationIdentity?

    /// Whether the current evidence satisfies all qualification requirements.
    public var isReady: Bool { ok && (source == .seeded || source == .autoProbed) }

    /// Decodes validated public engine evidence; malformed values are rejected.
    public init?(_ value: JSONValue) {
        guard let ok = value["ok"]?.boolValue,
              let rawSource = value["source"]?.stringValue,
              let source = Source(rawValue: rawSource) else { return nil }
        self.ok = ok
        self.source = source
        reason = String((value["reason"]?.stringValue ?? "").prefix(1000))
        identity = value["identity"].flatMap(BackendQualificationIdentity.init)
    }
}

// MARK: - BackendQualificationRequirement

/// Engine-declared candidate and required features for one immutable launch request.
public struct BackendQualificationRequirement: Equatable, Sendable {
    /// Stable engine feature or candidate identifier.
    public let id: String
    /// Engine backend identifier.
    public let backend: String
    /// Feature names the engine requires for this candidate.
    public let requiredFeatures: [String]
    /// Installed harness identity associated with these results.
    public let identity: BackendQualificationIdentity?
    /// Feature evidence keyed by the engine feature name.
    public let features: [String: BackendQualificationFeature]
    /// Bounded engine explanation when this candidate is unavailable.
    public let unavailableReason: String?

    /// Missing identity, missing features, and runtime failures remain unavailable.
    public var isReady: Bool {
        guard unavailableReason == nil else { return false }
        if requiredFeatures.isEmpty { return true }
        guard let identity, identity.backend == backend else { return false }
        return requiredFeatures.allSatisfy { name in
            guard let feature = features[name], feature.isReady else { return false }
            return feature.identity == identity
        }
    }

    /// Decodes validated public engine evidence; malformed values are rejected.
    public init?(_ value: JSONValue) {
        guard let id = value["id"]?.stringValue, !id.isEmpty,
              let backend = value["backend"]?.stringValue, !backend.isEmpty,
              let names = value["required_features"]?.arrayValue, names.count <= 64,
              let rows = value["features"]?.objectValue, rows.count <= 64 else { return nil }
        let required = names.compactMap(\.stringValue)
        guard required.count == names.count, required.allSatisfy({ !$0.isEmpty }),
              Set(required).count == required.count else { return nil }
        var features: [String: BackendQualificationFeature] = [:]
        for (name, row) in rows {
            guard !name.isEmpty, let feature = BackendQualificationFeature(row) else { return nil }
            features[name] = feature
        }
        self.id = id
        self.backend = backend
        requiredFeatures = required
        identity = value["identity"].flatMap(BackendQualificationIdentity.init)
        self.features = features
        unavailableReason = value["unavailable_reason"]?.stringValue.map { String($0.prefix(1000)) }
    }
}

// MARK: - BackendQualificationPlan

/// Cached-only discovery, independently versioned from permission preview.
public struct BackendQualificationPlan: Equatable, Sendable {
    /// Every engine-declared candidate for this operation.
    public let requirements: [BackendQualificationRequirement]

    /// Whether the current evidence satisfies all qualification requirements.
    public var isReady: Bool { requirements.allSatisfy(\.isReady) }

    /// Decodes only supported cached-only qualification plans.
    public init?(_ payload: [String: JSONValue]) {
        guard payload["qualification_version"]?.wireIntegerValue == 1,
              payload["discovery_only"]?.boolValue == true,
              let rows = payload["requirements"]?.arrayValue, rows.count <= 4096 else { return nil }
        let requirements = rows.compactMap(BackendQualificationRequirement.init)
        guard requirements.count == rows.count,
              Set(requirements.map(\.id)).count == requirements.count else { return nil }
        self.requirements = requirements
    }
}
