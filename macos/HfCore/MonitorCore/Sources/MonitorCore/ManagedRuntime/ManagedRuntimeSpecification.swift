import CryptoKit
import Foundation

// MARK: - ManagedRuntimeArtifact

/// A fixed binary input, verified before it can be installed or executed.
public struct ManagedRuntimeArtifact: Codable, Equatable, Sendable {
    public let name: String
    public let version: String
    public let filename: String
    public let url: URL
    public let sha256: String
    public let size: Int

    /// Constructs explicit managed runtime inputs without acquiring or discovering software.
    public init(name: String, version: String, filename: String, url: URL, sha256: String, size: Int) {
        self.name = name
        self.version = version
        self.filename = filename
        self.url = url
        self.sha256 = sha256
        self.size = size
    }

    func validate(wheel: Bool) throws {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              size > 0, size <= 64 << 20, sha256.count == 64,
              sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              filename == (filename as NSString).lastPathComponent,
              !filename.contains("\n"), !name.isEmpty, !version.isEmpty else {
            throw ManagedRuntimeFailure("Invalid managed runtime artifact specification.")
        }
        if wheel {
            guard url.host == "files.pythonhosted.org", filename.hasSuffix(".whl"),
                  url.lastPathComponent == filename,
                  name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }),
                  version.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".+".contains($0)) }) else {
                throw ManagedRuntimeFailure("Invalid locked binary wheel specification.")
            }
        }
    }
}

// MARK: - ManagedRuntimeSpecification

/// App-bundled acquisition inputs. No ambient settings or environment can override them.
public struct ManagedRuntimeSpecification: Codable, Equatable, Sendable {
    public let schema: Int
    public let engineVersion: String
    public let pythonVersion: String
    public let python: ManagedRuntimeArtifact
    public let dependencies: [ManagedRuntimeArtifact]
    public let provenance: String

    /// Constructs explicit managed runtime inputs without acquiring or discovering software.
    public init(schema: Int = 1, engineVersion: String, pythonVersion: String,
                python: ManagedRuntimeArtifact, dependencies: [ManagedRuntimeArtifact], provenance: String) {
        self.schema = schema
        self.engineVersion = engineVersion
        self.pythonVersion = pythonVersion
        self.python = python
        self.dependencies = dependencies
        self.provenance = provenance
    }

    /// Loads the exact interpreter and dependency pins packaged with the app.
    public static func bundled() throws -> Self {
        try bundled(bundleURL: Bundle.main.bundleURL, resourceURL: Bundle.main.resourceURL)
    }

    static func bundled(bundleURL: URL, resourceURL: URL?) throws -> Self {
        let url: URL?
        if bundleURL.pathExtension == "app" {
            url = resourceURL?.appendingPathComponent("MonitorCore_MonitorCore.bundle/ManagedRuntime.json")
        } else {
            url = Bundle.module.url(forResource: "ManagedRuntime", withExtension: "json")
        }
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            throw ManagedRuntimeFailure("The app is missing its managed runtime specification.")
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    /// Stable specification identity also binds completion receipts to dependency/interpreter pins.
    public var identity: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return ManagedRuntimeDigest.sha256((try? encoder.encode(self)) ?? Data())
    }

    /// Refuses unsupported or malformed pins before filesystem acquisition or execution.
    public func validate() throws {
        guard schema == 1, engineVersion == "0.0.2", pythonVersion == "3.13.16",
              python.version == pythonVersion, !dependencies.isEmpty,
              Set(dependencies.map(\.name)).count == dependencies.count,
              Set(dependencies.map(\.filename)).count == dependencies.count else {
            throw ManagedRuntimeFailure("Unsupported managed runtime specification.")
        }
        try python.validate(wheel: false)
        for wheel in dependencies { try wheel.validate(wheel: true) }
    }
}

// MARK: - ManagedRuntimeDigest

/// SHA256 transfer-integrity checking for pinned artifacts and completion receipts.
public enum ManagedRuntimeDigest {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - ManagedRuntimeFailure

/// User-facing acquisition or qualification failure, retained until an explicit retry.
public struct ManagedRuntimeFailure: Error, Sendable, LocalizedError {
    public let message: String
    /// Constructs explicit managed runtime inputs without acquiring or discovering software.
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
