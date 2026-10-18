import Combine
import Foundation
import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - UvResolution

/// Where `uv` itself lives, once discovery has located it.
public struct UvResolution: Equatable, Sendable {
    public let executable: String
    public let binDirectory: String

    public init(executable: String, binDirectory: String) {
        self.executable = executable
        self.binDirectory = binDirectory
    }
}

// MARK: - DiscoveryResult

/// One coherent snapshot of the login-PATH and `uv` probes, published together so a reader never
/// sees one half of a run mixed with the other half of a different one.
public struct DiscoveryResult: Equatable, Sendable {
    public let loginPath: String?
    public let uv: UvResolution?

    public init(loginPath: String?, uv: UvResolution?) {
        self.loginPath = loginPath
        self.uv = uv
    }
}

// MARK: - ToolEnvironmentRepository

/// Login-PATH and `uv` discovery, and the launch environment every process the app starts gets —
/// exactly `AppModel`'s `discoverEnvironment`/`environment`/`ctl`/`setup`. After a run publishes,
/// `locator` re-reads only the Settings override live (F4-05/decision 11) — the login-PATH and `uv`
/// probes never rerun on their own.
@Mockable
public protocol ToolEnvironmentRepository: Sendable {

    var home: String { get }
    var tasksDirectory: String { get }
    var locator: ToolLocator { get }
    var discovery: DiscoveryResult { get }
    func discoveryPublisher() -> AnyPublisher<DiscoveryResult, Never>

    /// Runs the login-PATH probe and `uv` discovery, coalesced and awaitable: a caller that arrives
    /// while a run is already in flight awaits a run that **started after its own call** (never the
    /// one already in progress) and gets that run's result.
    func discoverEnvironment() async -> DiscoveryResult

    func environment(toolDirectory: String?) -> [String: String]

    func ctl() -> Result<CtlClient, ToolError>
    func setup() -> Result<SetupClient, ToolError>
}

public extension ToolEnvironmentRepository {

    /// Convenience for the common case, mirroring `AppModel.environment(toolDirectory: String? = nil)`.
    func environment() -> [String: String] { environment(toolDirectory: nil) }
}

// MARK: - NullToolEnvironmentRepository

public struct NullToolEnvironmentRepository: ToolEnvironmentRepository {
    public init() {}
    public var home: String { NSHomeDirectory() }
    public var tasksDirectory: String { TaskTitle.tasksDirectory(home: home) }
    public var locator: ToolLocator { ToolLocator(overrideDirectory: nil, home: home, uvToolBin: nil, isExecutable: { _ in false }) }
    public var discovery: DiscoveryResult { DiscoveryResult(loginPath: nil, uv: nil) }
    public func discoveryPublisher() -> AnyPublisher<DiscoveryResult, Never> { Just(discovery).eraseToAnyPublisher() }
    public func discoverEnvironment() async -> DiscoveryResult { discovery }
    public func environment(toolDirectory _: String?) -> [String: String] { [:] }
    public func ctl() -> Result<CtlClient, ToolError> { .failure(.notFound(tool: "polybridge-ctl", searched: [])) }
    public func setup() -> Result<SetupClient, ToolError> { .failure(.notFound(tool: "polybridge-setup", searched: [])) }
}

// MARK: - GlobalValues

public extension GlobalValues {

    /// Global tool-environment repository.
    @GlobalEntry var toolEnvironmentRepository: any ToolEnvironmentRepository = NullToolEnvironmentRepository()
}
