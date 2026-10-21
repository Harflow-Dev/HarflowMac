import Foundation

// MARK: - ManagedRuntimeLayout

/// Immutable paths derived only from the selected home. Construction performs no I/O.
public struct ManagedRuntimeLayout: Equatable, Sendable {
    public let home: String
    public let stateRoot: String
    public let runtimeRoot: String
    public var tasksDirectory: String { stateRoot + "/tasks" }
    public var binDirectory: String { runtimeRoot + "/bin" }
    public var generationsDirectory: String { runtimeRoot + "/generations" }
    public var activePath: String { runtimeRoot + "/active" }

    /// Constructs explicit managed runtime inputs without acquiring or discovering software.
    public init(home: String) {
        self.home = LexicalStateRoot.normalize(home) ?? ""
        self.stateRoot = self.home + "/.harflow"
        self.runtimeRoot = self.home + "/Library/Application Support/Harflow/Runtime"
    }
}

// MARK: - ManagedRuntimeReady

/// Qualified generation-bound app tools. Stable external launchers may follow a newer active pointer.
public struct ManagedRuntimeReady: Equatable, Sendable {
    public let generationDirectory: String
    public let ctlExecutable: String
    public let setupExecutable: String
    public let environment: [String: String]

    /// Constructs explicit managed runtime inputs without acquiring or discovering software.
    public init(generationDirectory: String, environment: [String: String]) {
        self.generationDirectory = generationDirectory
        self.ctlExecutable = generationDirectory + "/bin/harflow-ctl"
        self.setupExecutable = generationDirectory + "/bin/harflow-setup"
        self.environment = environment
    }
}

// MARK: - ManagedRuntimeInstalling

/// Constructor-injected installer seam; an attempt either returns a qualified generation or fails.
public protocol ManagedRuntimeInstalling: Sendable {
    func prepare() async throws -> ManagedRuntimeReady
}
