import Foundation
import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - ToolEnvironmentRepository

/// Login-PATH and `uv` discovery, and the launch environment every process the app starts gets —
/// exactly `AppModel`'s `discoverEnvironment`/`environment`/`ctl`/`setup`. `discoverEnvironment()`
/// probes once; after that, `locator` re-reads only the Settings override live (F4-05/decision 11) —
/// the login-PATH and `uv` probes never rerun.
@Mockable
public protocol ToolEnvironmentRepository: Sendable {

    var home: String { get }
    var tasksDirectory: String { get }
    var locator: ToolLocator { get }

    /// Runs the login-PATH probe and `uv` discovery once. Safe to call more than once; later calls
    /// simply re-probe (callers are expected to call this exactly once, at startup).
    func discoverEnvironment() async

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
    public func discoverEnvironment() async {}
    public func environment(toolDirectory _: String?) -> [String: String] { [:] }
    public func ctl() -> Result<CtlClient, ToolError> { .failure(.notFound(tool: "polybridge-ctl", searched: [])) }
    public func setup() -> Result<SetupClient, ToolError> { .failure(.notFound(tool: "polybridge-setup", searched: [])) }
}

// MARK: - GlobalValues

public extension GlobalValues {

    /// Global tool-environment repository.
    @GlobalEntry var toolEnvironmentRepository: any ToolEnvironmentRepository = NullToolEnvironmentRepository()
}
